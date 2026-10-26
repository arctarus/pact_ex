# PactEx Architecture

This document describes how PactEx is built and how a consumer test flows from your ExUnit code down to the Pact mock server.

## Overview

PactEx is a Rustler NIF over [`pact_ffi`](https://github.com/pact-foundation/pact-reference/tree/master/rust/pact_ffi) 0.5.12, the Rust library behind most Pact implementations. The NIF crate (`native/pact_ex_nif`) depends on `pact_ffi` as a regular Rust crate and calls its `pactffi_*` functions directly. There is no C code and no downloaded `.a` file. Users get a precompiled NIF through `rustler_precompiled`.

The current release covers HTTP consumer tests: building interactions, running them against a mock server, and writing the pact file. Messages, plugins (gRPC) and provider verification are planned (see [Roadmap](#roadmap)).

## High-Level Architecture

```
┌──────────────────────────────────────────────────────────────────┐
│                   Your ExUnit test / application                 │
└───────────────────────────────┬──────────────────────────────────┘
                                │ PactEx.* API
┌───────────────────────────────▼──────────────────────────────────┐
│                       PactEx (Elixir, pure data)                 │
│  ┌────────────┐  ┌──────────────┐  ┌───────────────────────────┐ │
│  │ PactEx     │  │ PactEx.HTTP  │  │ PactEx.Matchers           │ │
│  │ (new/3)    │  │ (builders)   │  │ (like, regex, each_like…) │ │
│  └────────────┘  └──────────────┘  └───────────────────────────┘ │
│  ┌──────────────────────────────────────────────────────────────┐│
│  │ PactEx.Consumer        run/4, run!/4, start_mock_server/3    ││
│  │   ├─ Consumer.Apply    plan + encode (no FFI builder calls)  ││
│  │   └─ Consumer.BodyCheck  XML / form description checks       ││
│  └──────────────────────────────────────────────────────────────┘│
│  ┌────────────────┐ ┌─────────────┐ ┌──────────────────────────┐ │
│  │ PactEx.Mock-   │ │ PactEx.Log  │ │ PactEx.Error /           │ │
│  │ Server         │ │             │ │ PactEx.MismatchError     │ │
│  └────────────────┘ └─────────────┘ └──────────────────────────┘ │
└───────────────────────────────┬──────────────────────────────────┘
                                │ PactEx.Native (NIF stubs)
┌───────────────────────────────▼──────────────────────────────────┐
│                  pact_ex_nif (Rust, Rustler 0.38)                │
│  handles.rs   http.rs   mock_server.rs   content_type.rs         │
│  logger.rs    error.rs  stack.rs         args.rs                 │
│  - Resources for pact / interaction handles                      │
│  - Error mapping (thread-local last error → error map)           │
│  - Dirty schedulers + 8 MiB stack for blocking calls             │
└───────────────────────────────┬──────────────────────────────────┘
                                │ pactffi_* (Rust calls, C ABI)
┌───────────────────────────────▼──────────────────────────────────┐
│               pact_ffi 0.5.12 / pact_models 1.3.17               │
│  - Pact model, matching rules, generators                        │
│  - Mock server (Tokio runtime, own threads)                      │
│  - Pact file writing (with file locks)                           │
└──────────────────────────────────────────────────────────────────┘
```

## Core Components

### 1. Public API

- **`PactEx.new/3`** (`lib/pact_ex.ex`, `lib/pact_ex/pact.ex`): builds a `%PactEx.Pact{consumer, provider, spec, pact_dir}`. Defaults: spec `:v4`, `pact_dir` `"pacts"`. It is a plain struct; nothing native happens yet.
- **`PactEx.HTTP`** (`lib/pact_ex/http.ex`, `lib/pact_ex/http/*.ex`): pure builders that return immutable structs (`Interaction`, `Request`, `Response`): `interaction/1`, `given/2,3`, `with_request/4`, `will_respond_with/3`. They validate their input (guards and `Keyword.validate!/2`) and normalise `headers:` and `query:` given as maps, keyword lists or tuple lists. Atom header names are written the way Req writes them (`:x_request_id` becomes `x-request-id`).
- **`PactEx.Matchers`** (`lib/pact_ex/matchers.ex`): functions that return pact_ffi "integration JSON" maps (`%{"pact:matcher:type" => ...}`). Each example satisfies its own rule (for example, `each_like/2` repeats the example `min` times).

### 2. Consumer Layer

#### `PactEx.Consumer` (`lib/pact_ex/consumer.ex`)
The entry point for tests.
- `start_mock_server/3` validates every interaction, creates a fresh FFI pact, applies the interactions and starts the mock server. It returns a `%PactEx.MockServer{}`.
- `run/4` wraps it:
  1. start the server;
  2. call your function;
  3. check that every expected request arrived and no other did;
  4. write the pact in merge mode.

  The server is stopped in an `after` block, so it stops when the function returns, raises, throws or exits. Nothing is written on a mismatch or an exception.
- `run!/4` raises the error instead of returning it.

There is no GenServer and no shared state. Every `run/4` call gets its own pact handle and mock server, so `async: true` tests are safe.

#### PactEx.Consumer.Apply (`lib/pact_ex/consumer/apply.ex`, internal)
Turns an `Interaction` into native calls in two phases:
- **Plan:** `plan/1` decides everything before any FFI builder call:
  - the encoding of query, header and path values (strings, matchers, scalars, lists);
  - one canonical content type per part (explicit `:content_type`, then the `Content-Type` header, then the body default; each trimmed and checked with pact_models' own parser);
  - the canonical `Content-Type` header;
  - the rejection of values pact_ffi would drop or crash on.
- **Apply:** `interaction/2` creates the interaction handle and calls the builder NIFs with exactly what the plan decided.

Every JSON PactEx writes is decoded again with a decoder that fails on a repeated key. So the bytes checked are exactly the bytes sent.

#### PactEx.Consumer.BodyCheck (`lib/pact_ex/consumer/body_check.ex`, internal)
pact_ffi reads a JSON body under an XML or `application/x-www-form-urlencoded` content type as a *description* of the body. Some descriptions make pact_ffi panic inside an `extern "C"` function, which aborts the BEAM. `BodyCheck` validates those descriptions, including string bodies that pact_ffi's sniffing takes for JSON, and returns `{:error, %PactEx.Error{code: -101}}` naming the interaction and the path of the problem.

### 3. Mock Server (`lib/pact_ex/mock_server.ex`)

`%PactEx.MockServer{port, url, pact_dir, pact_ref}` wraps a running pact_ffi mock server:
- `matched?/1`
- `mismatches/1` (decoded JSON)
- `write_pact/2` (merge by default)
- `stop/1`

It keeps a reference to the pact resource, so the pact handle lives as long as the server struct.

### 4. Logging (`lib/pact_ex/log.ex`)

`PactEx.Log.init/1` configures pact_ffi's global logger (stdout, stderr or a file, at a given level). pact_ffi installs one logger per OS process, so `init/1` succeeds once. Later calls return `{:error, :already_initialized}`. No log callbacks are registered, because they would fire on Tokio threads.

### 5. Errors (`lib/pact_ex/error.ex`, `lib/pact_ex/mismatch_error.ex`)

- `PactEx.Error` has fields `function`, `code` and `message`. Codes:
  - `-100`: an argument contained a NUL byte. It is rejected before calling pact_ffi.
  - `-101`: PactEx rejected an interaction before calling pact_ffi, because it is invalid or pact_ffi would drop or crash on it.
  - Other codes come from pact_ffi. The message is pact_ffi's own error text when it stored one, or a description of the code.
- `PactEx.MismatchError` carries the decoded mismatch list from the mock server: missing requests, unexpected requests, body or header mismatches.

### 6. NIF Layer

#### Elixir side (`lib/pact_ex/native.ex`)
**PactEx.Native** uses `RustlerPrecompiled`:
- It downloads the NIF for the current target, or builds it from source in dev/test, or when `PACT_EX_BUILD=1`.
- It declares a stub for each NIF.
- It is `@moduledoc false`. Users never call it directly.

#### Rust side (`native/pact_ex_nif/src/`)

| File | Responsibility |
|---|---|
| `handles.rs` | `PactResource` / `InteractionResource` (Rustler resources). `Drop` hands the pact to a background reaper thread, which cleans up its plugins (once) and frees the handle. An interaction keeps its pact alive. NIFs, all on dirty IO schedulers: `new_pact`, `with_specification`, `new_interaction`, `given`, `given_with_params`. |
| `http.rs` | Request and response builders: `with_request`, `with_query_parameter`, `with_header`, `with_body`, `with_binary_body`, `response_status`. All on dirty IO schedulers. |
| `mock_server.rs` | `create_mock_server`, `mock_server_matched`, `mock_server_mismatches`, `write_pact_file`, `cleanup_mock_server`. All on dirty IO schedulers. A crate-level mutex serialises reading mismatches and cleanup. |
| `content_type.rs` | Pure helpers that reuse pact_models and serde_json: `content_type_kind` (parse and classify a content type), `detect_json` (pact_models' JSON sniffing) and `json_text_shape` (serde_json parse). The last two run on dirty CPU schedulers. |
| `logger.rs` | `init_logger`: logger init, attach sink and apply, in one call. |
| `error.rs` | `FfiError`, `Outcome`, `clear_error` / `last_error` (thread-local pact_ffi error message), `to_cstring` (NUL check). |
| `stack.rs` | `on_large_stack`: runs a closure on a thread with an 8 MiB stack. |
| `args.rs` | `decode_arg`, so an unknown atom raises `ArgumentError`. |

### 7. pact_ffi (external)

Provides the Pact model, matching rules and generators, the mock server (on its own Tokio runtime), and pact file writing. pact_models serialises concurrent merges of the same pact file with a process mutex and a file lock.

## Data Flow

### Consumer workflow

```elixir
pact = PactEx.new("web", "users-api")

interaction =
  PactEx.HTTP.interaction("get user")
  |> PactEx.HTTP.given("user 1 exists")
  |> PactEx.HTTP.with_request(:get, "/users/1")
  |> PactEx.HTTP.will_respond_with(200, body: %{"id" => PactEx.Matchers.integer(1)})

:ok = PactEx.Consumer.run(pact, [interaction], fn mock ->
  Req.get!(mock.url <> "/users/1")
end)
```

1. **Build (pure Elixir).** `PactEx.new/3` and the `PactEx.HTTP` builders produce structs. Matchers are plain maps.
2. **Validate (no FFI builder calls).** `start_mock_server/3` runs `Apply.validate/1` on every interaction. Invalid input returns `{:error, %PactEx.Error{code: -101}}`, and nothing native has been created yet.
3. **Create the pact.** `Native.new_pact/2` returns a resource, and `Native.with_specification/2` sets the spec.
4. **Apply.** For each interaction:
   - `Native.new_interaction/2`, then `given` / `given_with_params`;
   - the request: `with_request`, `with_query_parameter`, `with_header`, `with_body` or `with_binary_body`;
   - the response: `response_status`, `with_header`, `with_body`.
5. **Start.** `Native.create_mock_server/5` binds `127.0.0.1` on an OS-chosen port by default.
6. **Exercise.** Your function talks to `mock.url`.
7. **Verify and write.** `MockServer.matched?/1`:
   - matched: `MockServer.write_pact/2` writes `<consumer>-<provider>.json` in merge mode;
   - not matched: `run/4` reads the mismatches into a `PactEx.MismatchError`;
   - not matched, with no mismatch details (a plugin mock server that failed to answer, or a server `fun` already stopped): `run/4` returns a `PactEx.Error` with code `-102` and writes nothing.
8. **Stop.** `MockServer.stop/1` runs last, because the mock server owns the mismatches JSON and frees it on cleanup.

### Provider workflow

Not implemented yet. Provider verification is planned (see [Roadmap](#roadmap)).

## Threading and Safety

- **Dirty schedulers:** NIFs that block or take a pact_ffi mutex across I/O run on dirty IO schedulers: mock server creation, matching, mismatches, writing, cleanup and logger init, and every builder NIF (they wait for pact_ffi's global `PACT_HANDLES` mutex, which it holds across plugin round trips). Freeing a pact happens on a background reaper thread, not on the scheduler that drops the resource. The JSON sniffing and parsing helpers run on dirty CPU schedulers, because bodies can be large.
- **Large stack:** blocking calls run inside `on_large_stack/1` (an 8 MiB thread). Futures that pact_ffi drives with `block_on` run their outer frames on the calling thread, and dirty scheduler stacks are small.
- **Thread-local errors:** pact_ffi stores its last error message in a thread-local. Each fallible NIF calls `clear_error`, the FFI function and `last_error` on the same thread, inside the same NIF call (inside `on_large_stack` when one is used).
- **Use after free:** the mismatches string is owned by the mock server manager. A crate mutex is held across the mismatches read and copy, and across cleanup.
- **VM aborts:** a panic inside pact_ffi's `extern "C"` functions cannot unwind into the BEAM, so it aborts the whole VM. PactEx therefore validates every input pact_ffi is known to crash on (XML and form descriptions, empty `Content-Type` values, repeated JSON keys) before any native call. The abort matrix test (`test/abort_matrix_test.exs`) runs each risky input in its own OS process, so an abort is a test failure, not a dead suite.

## Build System

### Native dependencies
- The Rust crate `pact_ex_nif` pins `pact_ffi = "=0.5.12"`, `pact_models = "=1.3.17"` and `rustler = "0.38"`, plus `serde_json`. `Cargo.lock` is committed and shipped.
- Minimum Rust is 1.91 (`rust-version`). No `protoc` is needed.

### Compilation
- **Users:** `rustler_precompiled` downloads the NIF for their target from the GitHub release and checks it against `checksum-Elixir.PactEx.Native.exs`.
- **Dev/test:** `config/config.exs` forces a source build. Elsewhere, `PACT_EX_BUILD=1` forces one too. It is read at compile time, so changing it needs `mix deps.compile pact_ex --force`.

### Platforms
- The targets are macOS, Linux glibc and Linux musl, each on `x86_64` and `aarch64`, for NIF versions 2.16 and 2.17. There is no Windows build.
- Measured glibc floors: x86_64-gnu needs 2.34, and aarch64-gnu needs 2.18.

### CI and release (`.github/workflows/`)
- **`ci.yml`:**
  - runs the tests (including the abort matrix), `cargo test`, fmt, clippy and `--warnings-as-errors`;
  - matrix: Linux and macOS, with OTP 26/27/28.
- **`release.yml`:**
  - builds the 12 NIFs with `philss/rustler-precompiled-action` and checks that each tarball holds only `libpact_ex_nif`;
  - checks the glibc floor;
  - on pull requests that touch native code, and on manual runs, it is a dry run: builds and checks only;
  - publishes a GitHub release only for `v*` tag pushes.
- Actions are pinned by commit SHA. See `RELEASING.md`.

## Error Handling

### Propagation
1. **pact_ffi** returns a status code, a boolean or a null pointer, and sets a thread-local error message.
2. **NIF** turns that into `:ok`, `{:ok, value}` or `{:error, %{function, code, message}}`. Bad argument types and NUL bytes in handle-creating calls raise `ArgumentError`.
3. **Elixir** wraps error maps in `%PactEx.Error{}`. `run/4` returns `{:error, %PactEx.Error{}}` or `{:error, %PactEx.MismatchError{}}`, and `run!/4` raises them.

### Resources
- Pact handles are released when the last reference is garbage collected. The resource destructor does not free the pact itself: it hands it to the `pact_ex_reaper` thread, which cleans up the pact's plugins (once) and then frees it, asynchronously. Explicit `cleanup_plugins` is still the way to stop plugin processes promptly.
- Mock servers are stopped by `run/4` in an `after` block, or explicitly with `MockServer.stop/1`. A brutal kill (an ExUnit timeout or a linked crash) skips `after`, and the server lives until the OS process exits.

## Configuration

- **Pact:**
  - `consumer` and `provider` names;
  - `spec` (`:v2`, `:v3`, `:v4`; default `:v4`);
  - `pact_dir` (default `"pacts"`).
- **Mock server:** `host` (default `"127.0.0.1"`) and `port` (default `0`, OS-assigned) in `start_mock_server/3` and `run/4`.
- **Logging:** `PactEx.Log.init(level: ..., sink: :stdout | :stderr | {:file, path})`.
- **Build:** `PACT_EX_BUILD=1` builds from source.

## Testing

| Location | Scope |
|---|---|
| `native/pact_ex_nif/src/*.rs` (`cargo test`) | Rust unit tests: error mapping, the large stack, the lock, content type helpers, logger messages, the reaper thread and the cleanup-once guard. One `#[ignore]` test needs the protobuf plugin 0.8.1 installed: `cargo test -- --ignored`. |
| `test/pact_ex/native/` | The NIFs against the real pact_ffi: success and error paths, large bodies, mock server queries. `scheduler_test.exs` checks that builder NIFs run on dirty IO schedulers, measured with microstate accounting. |
| `test/pact_ex/` | Builders, matchers, `Apply`, `BodyCheck`, `Consumer`, `MockServer`, `Log`, end to end with a real mock server, Req and checks of the pact file. |
| `test/acceptance/` | The pact_erlang HTTP parity suite, an end-to-end test per matcher, concurrent writes of the same pact file. |
| `test/abort_matrix_test.exs` | Risky inputs, each in its own OS process, with a pinned outcome. |

## Roadmap

Plans live in `docs/superpowers/plans/`:
- **Plan 2:** async and sync messages, Pact plugins (`pactffi_using_plugin`, `pactffi_interaction_contents`) and the gRPC mock transport through the protobuf plugin.
- **Plan 3:** provider verification from files, directories, URLs or a Pact Broker. It covers state change callbacks and message providers through an internal Plug endpoint, publishing results, and plugin transports.

Open follow-ups are tracked in `TODO.md`.
