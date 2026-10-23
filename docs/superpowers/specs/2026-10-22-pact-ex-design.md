# pact_ex — Design

Pact contract testing for Elixir, built as a Rustler NIF over `pact_ffi`. It aims for feature parity with
[pact_erlang](https://github.com/greyorange-labs/pact_erlang) plus the Pact plugin system (gRPC, protobuf, etc.).

## Research findings

Sources: `pact-reference` (master, `pact_ffi` 0.5.12), `pact_erlang` 0.3.2, `pact-go` v2.

- `pact_ffi` builds as `cdylib`, `staticlib` and `rlib`, and is published on crates.io (0.5.12, 2026-10-20).
  Its modules (`mock_server`, `verifier`, `plugins`, `log`, `error`) are `pub`, so a Rust crate can call the
  `pactffi_*` functions directly without a C toolchain or downloaded `.a` files.
- `pact_ffi` uses `rustls` (no OpenSSL). `onig` needs a C compiler at build time, which `cross` provides.
- The last error message lives in a `thread_local!` (`error/last_error.rs`). It must be read on the same OS
  thread, inside the same NIF call, as the failing FFI call.
- Many FFI calls run `RUNTIME.block_on(...)` on the caller's thread: `create_mock_server_for_transport`,
  `using_plugin` (sleeps 500 ms by default), `interaction_contents`, `verifier_execute`, the write functions.
  They block, so they must run on dirty IO schedulers. The future's outer frames also run on the caller's
  stack.
- pact_erlang (C NIF + static `libpact_ffi.a` 0.4.27):
  - Marks only the verifier NIFs as dirty.
  - On Linux, runs broker verification in a `fork()`/`execve` helper because the in-NIF call segfaulted
    (PR #49, root cause never found). One plausible cause is that the dirty scheduler stack is much smaller
    than the 2 MiB Rust stacks Tokio expects. This design runs blocking FFI calls on a spawned thread with
    an 8 MiB stack. Plan 3 starts with a spike to confirm that this removes the segfault.
  - Keeps per-pact state in a GenServer (`pact_ref_server`). We don't need one (see below).
  - Has no plugin, sync message or gRPC support.
- pact-go drives gRPC like this:
  1. `NewSynchronousPact`.
  2. `UsingPlugin{protobuf, version}` → `pactffi_using_plugin`.
  3. `WithContents(json, "application/protobuf")` → `pactffi_interaction_contents`.
  4. `StartTransport("grpc", ...)` → `pactffi_create_mock_server_for_transport(..., "grpc", ...)`.
  5. On the provider side, `Transports: [{Protocol: "grpc", Port: n}]` → `pactffi_verifier_add_provider_transport`.
- Plugins are separate OS processes. They must be installed under `~/.pact/plugins` (or `PACT_PLUGIN_DIR`)
  and released with `pactffi_cleanup_plugins`, or they keep running.
- `pact_models` 1.3.17 `write_pact` holds an in-process `WRITE_LOCK` mutex plus a blocking exclusive file
  lock, so concurrent `write_pact_file(..., overwrite=false)` calls for the same consumer/provider pair merge
  safely.
- Spike (2026-10-22): a throwaway crate with `pact_ffi = "=0.5.12"`, `pact_models = "=1.3.17"` and
  `rustler = "0.38"` compiles from crates.io and resolves every symbol plan 1 uses. It does not need `protoc`.
  `pactffi_with_specification` takes `pact_models::PactSpecification`, so the NIF crate pins `pact_models`
  to the same version.
- Hex: `pact_elixir` is taken (abandoned, 2022). `pact_ex` is free.

## Decisions

| Topic | Decision |
|---|---|
| Package / root module | `pact_ex` / `PactEx` |
| Native layer | Rustler NIF crate `native/pact_ex_nif` that depends on `pact_ffi = "=0.5.12"` and `pact_models = "=1.3.17"` from crates.io |
| Distribution | `rustler_precompiled`. NIFs are built in GitHub Actions for 6 targets and NIF versions 2.16 and 2.17 |
| Platforms | `x86_64`/`aarch64` × `linux-gnu`/`linux-musl`/`apple-darwin`. No Windows |
| Floors | Elixir `~> 1.18` (built-in `JSON` module), OTP 26+, Rust 1.91+ (rustler 0.38 `rust-version`) |
| Handles | `PactHandle` and `InteractionHandle` are wrapped in Rustler resources. Freeing happens on GC (`Drop` calls `pactffi_free_pact_handle`). An interaction resource holds the pact resource alive |
| Blocking calls | `schedule = "DirtyIo"`, and the body runs on a spawned 8 MiB-stack thread that also reads the last error |
| Errors | NIFs return `:ok` / `{:ok, v}` / `{:error, %{function: String.t(), code: integer(), message: String.t()}}`. Elixir raises `PactEx.Error` only in `!` functions |
| State | No GenServer. Interactions are plain immutable structs. The FFI pact is created and populated only inside `PactEx.Consumer.start_mock_server/3`, so each test gets its own handle |
| Callbacks | No FFI log or plugin log callbacks (they fire on Tokio threads). Logging goes to file, stdout, stderr or buffer sinks |
| Log init | `pact_ffi` installs a global logger once per OS process. `PactEx.Log.init/1` succeeds once, and later calls return `{:error, :already_initialized}` |

## Public API sketch

```elixir
pact = PactEx.new("my_app", "user_service", pact_dir: "pacts")   # pure struct, spec defaults to :v4

interaction =
  PactEx.HTTP.interaction("get user by id")
  |> PactEx.HTTP.given("user exists", %{"id" => "123"})
  |> PactEx.HTTP.with_request(:get, "/users/123", headers: %{"accept" => "application/json"})
  |> PactEx.HTTP.will_respond_with(200, body: %{"id" => like(123), "name" => like("John")})

:ok =
  PactEx.Consumer.run(pact, [interaction], fn mock ->
    {:ok, _} = UserClient.get(mock.url, "123")
  end)
```

`run/3` starts the mock server, runs the function, checks that every interaction matched, writes the pact
(merge mode), and always stops the mock server. Lower-level parity functions are `start_mock_server/3`,
`PactEx.MockServer.matched?/1`, `mismatches/1`, `write_pact/2` and `stop/1`.

## pact_erlang parity checklist

| pact_erlang | pact_ex | Plan |
|---|---|---|
| `pact:v4/2` | `PactEx.new/3` | 1 |
| `pact:interaction/2` (given ± params, upon_receiving, request method/path/headers/query/body, response status/headers/body) | `PactEx.HTTP.*` + `PactEx.Consumer.start_mock_server/3` | 1 |
| `pact:verify/1` | `PactEx.MockServer.matched?/1`, `mismatches/1` | 1 |
| `pact:write/1,2` | `PactEx.MockServer.write_pact/2` | 1 |
| `pact:cleanup/1` | `PactEx.MockServer.stop/1` | 1 |
| `pact:like/1`, `each_like/1`, `regex_match/2`, `each_key/2` | `PactEx.Matchers` | 1 |
| `pact:enable_logging/1,2` | `PactEx.Log.init/1` | 1 |
| `pact:msg_interaction/2` (async message + reify) | `PactEx.Message` | 2 |
| — (new) plugins, sync messages, gRPC transport | `PactEx.Plugin`, `PactEx.SyncMessage` | 2 |
| `pact_verifier:start_verifier/2`, `verify/1` (file + broker sources, message providers, state change URL, publish results) | `PactEx.Verifier` | 3 |
| — (new) provider transports (`grpc`) | `PactEx.Verifier` | 3 |

## Plans

1. **Core + HTTP consumer**: NIF scaffold, distribution, HTTP consumer, matchers, logging.
   `docs/superpowers/plans/2026-10-22-pact-ex-1-core-http-consumer.md`
2. **Messages + plugins**: async and sync messages, `using_plugin`, `interaction_contents`, gRPC mock
   transport, plugin cleanup. Acceptance test: the pact-go `examples/grpc` RouteGuide consumer.
   `docs/superpowers/plans/2026-10-22-pact-ex-2-messages-plugins.md`
3. **Provider verifier** (`docs/superpowers/plans/2026-10-22-pact-ex-3-provider-verifier.md`): starts with a spike that reproduces the PR #49 segfault on `pact_ffi` 0.5.12 and
   checks the large-stack mitigation. If an external process is still needed, it is launched via an Elixir
   `Port`, never with C `fork`. Then: file, directory and broker sources, state change URL, message
   providers over an internal Plug endpoint, publish options, and provider transports.

## Risks

- Building `pact_ffi` from source takes minutes. This affects CI and contributors only, since users get
  precompiled NIFs. Mitigation: Cargo cache in CI.
- `pact_ffi` 0.5.x API churn. Mitigation: exact version pin, and upgrades only in deliberate PRs.
- A segfault in native code still takes down the BEAM. `pact_ffi` and Rustler catch panics, but not
  segfaults.
