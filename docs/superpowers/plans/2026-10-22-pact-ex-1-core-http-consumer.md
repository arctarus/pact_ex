# pact_ex — Plan 1: Core + HTTP Consumer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship a Hex-publishable `pact_ex` library that writes HTTP consumer pacts from ExUnit tests. It runs on a Rustler NIF over `pact_ffi` 0.5.12, with pact_erlang parity for the HTTP consumer, matchers and logging.

**Architecture:** A Rustler crate (`native/pact_ex_nif`) depends on the `pact_ffi` crate and exposes thin NIFs over its handles. `PactHandle` and `InteractionHandle` are wrapped in Rustler resources. The Elixir side is pure data until `PactEx.Consumer.start_mock_server/3`, which creates a fresh FFI pact, applies the interactions and starts the mock server. There is no GenServer and no shared mutable state between tests.

**Tech Stack:** Elixir ~> 1.18 (built-in `JSON`), OTP 26+, Rust 1.88+, `rustler` 0.38 (crate and Hex), `rustler_precompiled` ~> 0.10, `pact_ffi` =0.5.12, `req` (test only).

**Spec:** `docs/superpowers/specs/2026-10-22-pact-ex-design.md`

## Global Constraints

- Package `pact_ex`, root module `PactEx`, NIF module `PactEx.Native`, Rust crate `pact_ex_nif` at `native/pact_ex_nif`.
- `pact_ffi = "=0.5.12"` and `pact_models = "=1.3.17"` (exact pins). `pact_ffi`'s FFI signatures use `pact_models` types, so the versions must match. `rustler = "0.38"` in Cargo and `{:rustler, "~> 0.38", optional: true}` in mix. Verified on 2026-10-22: this set compiles from crates.io without `protoc`.
- Commit `native/pact_ex_nif/Cargo.lock` and ship it in the Hex package.
- Precompiled targets: `aarch64-apple-darwin x86_64-apple-darwin aarch64-unknown-linux-gnu x86_64-unknown-linux-gnu aarch64-unknown-linux-musl x86_64-unknown-linux-musl`. NIF versions `["2.16", "2.17"]`.
- Source URL: `https://github.com/arctarus/pact_ex`. This is an assumption; confirm before Task 9.
- Defaults: spec `:v4`, `pact_dir` `"pacts"`, mock server host `"127.0.0.1"`, port `0` (OS-assigned).
- Pact files are named `<consumer>-<provider>.json`. `PactEx.Consumer.run/4` writes in merge mode (`overwrite: false`).
- Every blocking FFI call (`create_mock_server`, `write_pact_file`, `cleanup_mock_server`) is a `schedule = "DirtyIo"` NIF whose body runs inside `on_large_stack/1`.
- Every NIF that can fail calls `clear_error()` right before the FFI call, and reads `pactffi_get_error_message` in the same NIF call and on the same thread as the failing FFI call. Scheduler threads are shared, so a stale message from another test's call may still be in the thread-local.
- Error map shape returned by NIFs: `%{function: String.t(), code: integer(), message: String.t()}`.
- No FFI log callbacks or plugin log callbacks.
- Code, docs and commit messages are in English. `mix format` and `cargo fmt` are clean before every commit.

## Review Focus

1. **Non-JSON bodies.** A raw string body with an explicit content type (e.g. `text/plain`, XML) is sent byte for byte. A non-UTF-8 binary goes through `with_binary_body`. Tested in Task 6.
2. **Test function raises inside `run/4`.** The mock server is still stopped, no pact is written, and the original exception is re-raised. Tested in Task 6.
3. **Interaction never exercised.** `run/4` returns `{:error, %PactEx.MismatchError{}}` that names the missing request, and writes no pact file. Tested in Task 6.
4. **Concurrent writers.** Several processes write the same consumer/provider pact at once, and the merged file holds every interaction. Tested in Task 8.
5. **Multi-valued headers and query params, and matcher values in headers.** `query: %{"tag" => ["a", "b"]}` matches `?tag=a&tag=b`. A header value given as a matcher is JSON-encoded, not stringified. Tested in Task 6.

---

### Task 1: Project scaffold and loadable NIF

**Files:**
- Create: `mix.exs`, `.formatter.exs`, `.gitignore`, `config/config.exs`, `lib/pact_ex.ex`, `lib/pact_ex/native.ex`
- Create: `native/pact_ex_nif/Cargo.toml`, `native/pact_ex_nif/src/lib.rs`, `native/pact_ex_nif/.cargo/config.toml`
- Test: `test/test_helper.exs`, `test/pact_ex/native_test.exs`

**Interfaces:**
- Produces: `PactEx.Native.version() :: String.t()` (the `pact_ffi` version).

- [ ] **Step 1: Initialise repo and Mix project**

Run from `/home/arctarus/Code/elixir/pact-elixir`: `git init && echo y | mix new . --app pact_ex --module PactEx`
Expected: `mix.exs` and `lib/pact_ex.ex` created, and the `docs/` folder untouched.

- [ ] **Step 2: Configure `mix.exs`**

`elixir: "~> 1.18"`. Deps: `{:rustler_precompiled, "~> 0.10"}`, `{:rustler, "~> 0.38", optional: true}`, `{:req, "~> 0.5", only: :test}`, `{:ex_doc, ">= 0.0.0", only: :dev, runtime: false}`. `elixirc_paths(:test)` is `["lib", "test/support"]`. Package `files`: `~w(lib native/pact_ex_nif/src native/pact_ex_nif/Cargo.toml native/pact_ex_nif/Cargo.lock native/pact_ex_nif/.cargo checksum-*.exs mix.exs README.md CHANGELOG.md LICENSE)`.

`config/config.exs`: `config :rustler_precompiled, :force_build, pact_ex: config_env() in [:dev, :test]`.

`.gitignore` adds `native/pact_ex_nif/target/`, `priv/native/` and `pacts/`.

- [ ] **Step 3: Write the failing test**

```elixir
# test/pact_ex/native_test.exs
defmodule PactEx.NativeTest do
  use ExUnit.Case, async: true

  test "NIF loads and reports the pinned pact_ffi version" do
    assert PactEx.Native.version() == "0.5.12"
  end
end
```

- [ ] **Step 4: Run it to make sure it fails**

Run: `mix test test/pact_ex/native_test.exs`
Expected: FAIL with `PactEx.Native.version/0 is undefined (module PactEx.Native is not available)`.

- [ ] **Step 5: Create the Rust crate**

`Cargo.toml`: `[lib] name = "pact_ex_nif"`, `crate-type = ["cdylib"]`. Deps: `rustler = "0.38"`, `pact_ffi = "=0.5.12"`, `pact_models = "=1.3.17"`. `[profile.release]` sets `strip = true` and `lto = "thin"`.

`.cargo/config.toml` (standard Rustler settings for macOS dynamic lookup and musl cdylib):

```toml
[target.'cfg(target_os = "macos")']
rustflags = ["-C", "link-arg=-undefined", "-C", "link-arg=dynamic_lookup"]

[target.x86_64-unknown-linux-musl]
rustflags = ["-C", "target-feature=-crt-static"]

[target.aarch64-unknown-linux-musl]
rustflags = ["-C", "target-feature=-crt-static"]
```

`src/lib.rs`: `#[rustler::nif] fn version() -> String` returns `CStr::from_ptr(pact_ffi::pactffi_version())` as an owned string. Then `rustler::init!("Elixir.PactEx.Native");`.

- [ ] **Step 6: Implement `PactEx.Native` in `lib/pact_ex/native.ex`**

`use RustlerPrecompiled` with `otp_app: :pact_ex`, `crate: "pact_ex_nif"`, `version: Mix.Project.config()[:version]`, `base_url: "https://github.com/arctarus/pact_ex/releases/download/v#{version}"`, `force_build: System.get_env("PACT_EX_BUILD") in ["1", "true"]`, and the targets and NIF versions from Global Constraints. Add the stub `def version, do: :erlang.nif_error(:nif_not_loaded)`. Mark the module `@moduledoc false`.

- [ ] **Step 7: Run test to verify it passes**

Run: `mix test test/pact_ex/native_test.exs`
Expected: PASS. The first build compiles `pact_ffi` and takes several minutes.

- [ ] **Step 8: Commit**

```bash
git add -A
git commit -m "feat: scaffold pact_ex with Rustler NIF over pact_ffi 0.5.12"
```

---

### Task 2: Native error handling, large-stack helper and handle resources

**Files:**
- Create: `native/pact_ex_nif/src/error.rs`, `native/pact_ex_nif/src/stack.rs`, `native/pact_ex_nif/src/handles.rs`
- Modify: `native/pact_ex_nif/src/lib.rs`, `lib/pact_ex/native.ex`
- Test: `test/pact_ex/native/handles_test.exs`

**Interfaces:**
- Consumes: `PactEx.Native.version/0` (Task 1).
- Produces (Rust, used by Tasks 3 and 7):
  - `error::FfiError { function: String, code: i64, message: String }` (`#[derive(NifMap)]`)
  - `error::clear_error()` (drains any stale thread-local message)
  - `error::last_error(function: &str, code: i64) -> FfiError`
  - `error::to_cstring(function: &str, s: &str) -> Result<CString, FfiError>`
  - `error::Outcome { Ok, Err(FfiError) }`, which implements `Encoder` and `From<Result<(), FfiError>>`
  - `stack::on_large_stack<T: Send + 'static>(f: impl FnOnce() -> T + Send + 'static) -> T`
  - `handles::PactResource { handle: PactHandle }`
  - `handles::InteractionResource { handle: InteractionHandle, pact: ResourceArc<PactResource> }`
  - `handles::Spec` (`NifUnitEnum`: `V2 | V3 | V4`)
- Produces (Elixir NIFs, all in `PactEx.Native`):
  - `new_pact(consumer :: String.t(), provider :: String.t()) :: reference()`
  - `with_specification(pact :: reference(), spec :: :v2 | :v3 | :v4) :: :ok | {:error, map()}`
  - `new_interaction(pact :: reference(), description :: String.t()) :: reference()`
  - `given(interaction :: reference(), state :: String.t()) :: :ok | {:error, map()}`
  - `given_with_params(interaction :: reference(), state :: String.t(), params_json :: String.t()) :: :ok | {:error, map()}`

- [ ] **Step 1: Write the failing tests**

```elixir
# test/pact_ex/native/handles_test.exs
defmodule PactEx.Native.HandlesTest do
  use ExUnit.Case, async: true
  alias PactEx.Native

  setup do
    pact = Native.new_pact("handles-consumer", "handles-provider")
    %{pact: pact, interaction: Native.new_interaction(pact, "an interaction")}
  end

  test "pact and interaction handles are resources", %{pact: pact, interaction: i} do
    assert is_reference(pact)
    assert is_reference(i)
  end

  test "with_specification accepts known versions", %{pact: pact} do
    assert Native.with_specification(pact, :v3) == :ok
    assert Native.with_specification(pact, :v4) == :ok
  end

  test "with_specification rejects unknown atoms", %{pact: pact} do
    assert_raise ArgumentError, fn -> Native.with_specification(pact, :v5) end
  end

  test "given and given_with_params succeed with valid input", %{interaction: i} do
    assert Native.given(i, "a user exists") == :ok
    assert Native.given_with_params(i, "a user exists", ~s({"id": 1})) == :ok
  end

  test "FFI error message is read in the same call that failed", %{interaction: i} do
    assert {:error, %{function: "pactffi_given_with_params", code: 2, message: message}} =
             Native.given_with_params(i, "a user exists", "not json")

    assert message =~ "expected"
  end

  test "strings with NUL bytes are rejected without calling the FFI", %{interaction: i} do
    assert {:error, %{code: -100, message: "argument contains a NUL byte"}} =
             Native.given(i, "bad\0state")
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/pact_ex/native/handles_test.exs`
Expected: FAIL with `PactEx.Native.new_pact/2 is undefined or private`.

- [ ] **Step 3: Implement `error.rs`**

- `clear_error`: call `pactffi_get_error_message` into a scratch buffer and discard the result. Reading the message also clears it.
- `last_error`: call `pact_ffi::error::pactffi_get_error_message` into a 1024-byte buffer. If the call returns a positive length, use that text. Otherwise use `"#{function} failed with code #{code}"`.
- `to_cstring`: on an interior NUL, return `FfiError { function, code: -100, message: "argument contains a NUL byte" }`.
- `Outcome` encodes as `:ok` or `{:error, map}`. Rustler encodes `Ok(())` as `{:ok, {}}`, which is why this type exists.

- [ ] **Step 4: Implement `stack.rs`**

`const LARGE_STACK: usize = 8 * 1024 * 1024;`. `on_large_stack` runs `f` on `std::thread::Builder::new().stack_size(LARGE_STACK).spawn(f)` and returns `join()`'s value. On a join error, call `std::panic::resume_unwind` so Rustler turns the panic into an Erlang error. Callers must read `last_error` inside `f`, not after it, because the error lives in a thread-local.

- [ ] **Step 5: Implement `handles.rs` and register NIFs in `lib.rs`**

- Both resources use `#[rustler::resource_impl] impl Resource for ...`.
- `impl Drop for PactResource` calls `pact_ffi::mock_server::handles::pactffi_free_pact_handle(self.handle)`.
- `InteractionResource` holds `pact: ResourceArc<PactResource>` so the pact outlives every interaction made from it.
- `Spec` maps to `pact_models::PactSpecification::{V2, V3, V4}`. This is the type `pactffi_with_specification` takes. pact_ffi's own `models::pact_specification::PactSpecification` is a different type and does not compile here.
- `given` and `with_specification` map a `false` return to `Outcome::Err(last_error(name, 1))`.
- `given_with_params` maps a non-zero code `c` to `last_error("pactffi_given_with_params", c)`.

Add the five Elixir stubs to `lib/pact_ex/native.ex`.

- [ ] **Step 6: Run tests to verify they pass**

Run: `mix test test/pact_ex/native/handles_test.exs`
Expected: PASS (6 tests).

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "feat(native): add handle resources, error mapping and large-stack runner"
```

---

### Task 3: Native HTTP interaction and mock server NIFs

**Files:**
- Create: `native/pact_ex_nif/src/http.rs`, `native/pact_ex_nif/src/mock_server.rs`
- Modify: `native/pact_ex_nif/src/lib.rs`, `lib/pact_ex/native.ex`
- Test: `test/pact_ex/native/mock_server_test.exs`

**Interfaces:**
- Consumes: `FfiError`, `Outcome`, `last_error`, `to_cstring`, `on_large_stack`, `PactResource`, `InteractionResource` (Task 2).
- Produces (Elixir NIFs in `PactEx.Native`; `part` is `:request | :response`):
  - `with_request(interaction, method :: String.t(), path :: String.t()) :: :ok | {:error, map()}`
  - `with_query_parameter(interaction, name :: String.t(), index :: non_neg_integer(), value :: String.t()) :: :ok | {:error, map()}`
  - `with_header(interaction, part, name :: String.t(), index :: non_neg_integer(), value :: String.t()) :: :ok | {:error, map()}`
  - `with_body(interaction, part, content_type :: String.t(), body :: String.t()) :: :ok | {:error, map()}`
  - `with_binary_body(interaction, part, content_type :: String.t(), body :: binary()) :: :ok | {:error, map()}`
  - `response_status(interaction, status :: String.t()) :: :ok | {:error, map()}`
  - `create_mock_server(pact, host :: String.t(), port :: non_neg_integer(), transport :: String.t(), config_json :: String.t() | nil) :: {:ok, pos_integer()} | {:error, map()}` (DirtyIo)
  - `mock_server_matched(port :: pos_integer()) :: boolean()`
  - `mock_server_mismatches(port :: pos_integer()) :: String.t() | nil`
  - `write_pact_file(port :: pos_integer(), dir :: String.t(), overwrite :: boolean()) :: :ok | {:error, map()}` (DirtyIo)
  - `cleanup_mock_server(port :: pos_integer()) :: boolean()` (DirtyIo)

- [ ] **Step 1: Write the failing tests**

```elixir
# test/pact_ex/native/mock_server_test.exs
defmodule PactEx.Native.MockServerTest do
  use ExUnit.Case, async: true
  alias PactEx.Native

  defp ping_pact do
    pact = Native.new_pact("native-consumer", "native-provider")
    :ok = Native.with_specification(pact, :v4)
    i = Native.new_interaction(pact, "a ping")
    :ok = Native.with_request(i, "GET", "/ping")
    :ok = Native.response_status(i, "200")
    :ok = Native.with_body(i, :response, "text/plain", "pong")
    pact
  end

  @tag :tmp_dir
  test "serves the interaction, reports a match and writes the pact", %{tmp_dir: dir} do
    {:ok, port} = Native.create_mock_server(ping_pact(), "127.0.0.1", 0, "http", nil)
    assert %{status: 200, body: "pong"} = Req.get!("http://127.0.0.1:#{port}/ping")
    assert Native.mock_server_matched(port)
    assert Native.write_pact_file(port, dir, false) == :ok
    assert File.exists?(Path.join(dir, "native-consumer-native-provider.json"))
    assert Native.cleanup_mock_server(port)
  end

  test "reports missing requests as mismatches" do
    {:ok, port} = Native.create_mock_server(ping_pact(), "127.0.0.1", 0, "http", nil)
    refute Native.mock_server_matched(port)
    assert Native.mock_server_mismatches(port) =~ "missing-request"
    assert Native.cleanup_mock_server(port)
  end

  test "invalid transport config JSON returns code -2" do
    assert {:error, %{function: "pactffi_create_mock_server_for_transport", code: -2}} =
             Native.create_mock_server(ping_pact(), "127.0.0.1", 0, "http", "not json")
  end

  test "binary body round-trips byte for byte" do
    pact = Native.new_pact("native-consumer", "native-provider")
    i = Native.new_interaction(pact, "binary")
    :ok = Native.with_request(i, "GET", "/bin")
    :ok = Native.response_status(i, "200")
    :ok = Native.with_binary_body(i, :response, "application/octet-stream", <<0, 255, 1>>)
    {:ok, port} = Native.create_mock_server(pact, "127.0.0.1", 0, "http", nil)
    assert %{body: <<0, 255, 1>>} = Req.get!("http://127.0.0.1:#{port}/bin", decode_body: false)
    assert Native.cleanup_mock_server(port)
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/pact_ex/native/mock_server_test.exs`
Expected: FAIL with `PactEx.Native.with_request/3 is undefined or private`.

- [ ] **Step 3: Implement `http.rs`**

- `Part` is a `NifUnitEnum` (`Request | Response`) mapped to `pact_ffi::mock_server::handles::InteractionPart`.
- Each NIF calls the matching `pactffi_*` function (`with_request`, `with_query_parameter_v2`, `with_header_v2`, `with_body`, `with_binary_body`, `response_status_v2`). A `false` return maps to `Outcome::Err(last_error(<ffi name>, 1))`.
- `with_binary_body` takes a `rustler::Binary` and passes its pointer and length.

- [ ] **Step 4: Implement `mock_server.rs`**

- `create_mock_server`, `write_pact_file` and `cleanup_mock_server` are `#[rustler::nif(schedule = "DirtyIo")]`. Each one builds the CStrings and then moves them, the copied `PactHandle` and the port into `on_large_stack`. The FFI call and `last_error` both run inside that closure.
- `create_mock_server` maps a negative return `c` to `last_error("pactffi_create_mock_server_for_transport", c)`.
- `write_pact_file` maps a non-zero return the same way.
- `mock_server_mismatches` copies the returned C string into a Rust `String` and does not free it, because `pactffi_cleanup_mock_server` owns that memory. A null return maps to `nil`.

- [ ] **Step 5: Run tests to verify they pass**

Run: `mix test test/pact_ex/native/mock_server_test.exs`
Expected: PASS (4 tests).

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "feat(native): add HTTP interaction and mock server NIFs"
```

---

### Task 4: Pure data model (`PactEx.Pact`, `PactEx.HTTP`)

**Files:**
- Create: `lib/pact_ex/pact.ex`, `lib/pact_ex/http.ex`, `lib/pact_ex/http/interaction.ex`, `lib/pact_ex/http/request.ex`, `lib/pact_ex/http/response.ex`
- Modify: `lib/pact_ex.ex` (delegate `new/3`)
- Test: `test/pact_ex/http_test.exs`

**Interfaces:**
- Produces:
  - `%PactEx.Pact{consumer: String.t(), provider: String.t(), spec: :v2 | :v3 | :v4, pact_dir: Path.t()}`
  - `PactEx.new(consumer, provider, opts \\ []) :: PactEx.Pact.t()`. Opts are `spec` (default `:v4`) and `pact_dir` (default `"pacts"`), validated with `Keyword.validate!/2`.
  - `%PactEx.HTTP.Interaction{description: String.t(), provider_states: [{String.t(), map() | nil}], request: Request.t() | nil, response: Response.t() | nil}`
  - `%PactEx.HTTP.Request{method: String.t(), path: String.t() | map(), query: %{String.t() => term()}, headers: %{String.t() => term()}, body: term(), content_type: String.t() | nil}`
  - `%PactEx.HTTP.Response{status: pos_integer(), headers: %{String.t() => term()}, body: term(), content_type: String.t() | nil}`
  - `PactEx.HTTP.interaction(description) :: Interaction.t()`
  - `PactEx.HTTP.given(interaction, state, params \\ nil) :: Interaction.t()` appends to `provider_states` in call order.
  - `PactEx.HTTP.with_request(interaction, method :: atom() | String.t(), path, opts \\ []) :: Interaction.t()` with opts `query`, `headers`, `body`, `content_type`. The method is stored upper-cased.
  - `PactEx.HTTP.will_respond_with(interaction, status, opts \\ []) :: Interaction.t()` with opts `headers`, `body`, `content_type`.

- [ ] **Step 1: Write the failing tests**

```elixir
# test/pact_ex/http_test.exs
defmodule PactEx.HTTPTest do
  use ExUnit.Case, async: true
  alias PactEx.HTTP

  test "new/3 applies defaults" do
    assert %PactEx.Pact{consumer: "c", provider: "p", spec: :v4, pact_dir: "pacts"} =
             PactEx.new("c", "p")
  end

  test "new/3 rejects unknown options" do
    assert_raise ArgumentError, fn -> PactEx.new("c", "p", pactdir: "x") end
  end

  test "builder keeps provider states in order and normalises the method" do
    i =
      HTTP.interaction("get user")
      |> HTTP.given("user exists", %{"id" => 1})
      |> HTTP.given("is admin")
      |> HTTP.with_request(:get, "/users/1", query: %{"full" => "true"}, headers: %{"accept" => "application/json"})
      |> HTTP.will_respond_with(200, body: %{"id" => 1})

    assert i.provider_states == [{"user exists", %{"id" => 1}}, {"is admin", nil}]
    assert %HTTP.Request{method: "GET", path: "/users/1", query: %{"full" => "true"}} = i.request
    assert %HTTP.Response{status: 200, body: %{"id" => 1}} = i.response
  end

  test "with_request rejects unknown options" do
    assert_raise ArgumentError, fn -> HTTP.interaction("x") |> HTTP.with_request(:get, "/", params: %{}) end
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/pact_ex/http_test.exs`
Expected: FAIL with `PactEx.new/2 is undefined`.

- [ ] **Step 3: Implement the structs and builder functions listed in Interfaces**

Every struct gets `@type t` and `@enforce_keys` for its required fields.

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test test/pact_ex/http_test.exs`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat: add pure Pact and HTTP interaction data model"
```

---

### Task 5: Matchers

**Files:**
- Create: `lib/pact_ex/matchers.ex`
- Test: `test/pact_ex/matchers_test.exs`

**Interfaces:**
- Produces `PactEx.Matchers`. Each function returns a map in pact_ffi integration JSON format:
  - `like(value)`
  - `each_like(value, opts \\ [min: 1])`
  - `regex(value, pattern)`
  - `each_key(value, pattern)`
  - `integer(value)`, `decimal(value)`, `boolean(value)`
  - `datetime(value, format)`
  - `include(substring)`

- [ ] **Step 1: Write the failing tests**

```elixir
# test/pact_ex/matchers_test.exs
defmodule PactEx.MatchersTest do
  use ExUnit.Case, async: true
  import PactEx.Matchers

  test "like/1" do
    assert like(1) == %{"pact:matcher:type" => "type", "value" => 1}
  end

  test "each_like/2 wraps the example in a list with a minimum" do
    assert each_like(%{"a" => 1}) == %{"pact:matcher:type" => "type", "value" => [%{"a" => 1}], "min" => 1}
    assert each_like("x", min: 2)["min"] == 2
  end

  test "regex/2" do
    assert regex("male", "(male|female)") ==
             %{"pact:matcher:type" => "regex", "value" => "male", "regex" => "(male|female)"}
  end

  test "each_key/2" do
    assert each_key(%{"happy" => true}, "(happy|ferocious)") == %{
             "pact:matcher:type" => "eachKey",
             "value" => %{"happy" => true},
             "rules" => [%{"pact:matcher:type" => "regex", "regex" => "(happy|ferocious)"}]
           }
  end

  test "typed matchers" do
    assert integer(1) == %{"pact:matcher:type" => "integer", "value" => 1}
    assert decimal(1.5) == %{"pact:matcher:type" => "decimal", "value" => 1.5}
    assert boolean(true) == %{"pact:matcher:type" => "boolean", "value" => true}
    assert include("ell") == %{"pact:matcher:type" => "include", "value" => "ell"}

    assert datetime("2026-10-22T10:00:00Z", "yyyy-MM-dd'T'HH:mm:ssX") ==
             %{"pact:matcher:type" => "datetime", "value" => "2026-10-22T10:00:00Z", "format" => "yyyy-MM-dd'T'HH:mm:ssX"}
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/pact_ex/matchers_test.exs`
Expected: FAIL with `undefined function like/1`.

- [ ] **Step 3: Implement `PactEx.Matchers`** returning exactly the maps the tests pin. Validate `each_like` opts with `Keyword.validate!(opts, min: 1)`.

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test test/pact_ex/matchers_test.exs`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat: add Pact matchers"
```

---

### Task 6: Consumer runner, mock server API and errors

**Files:**
- Create: `lib/pact_ex/consumer.ex`, `lib/pact_ex/consumer/apply.ex`, `lib/pact_ex/mock_server.ex`, `lib/pact_ex/error.ex`, `lib/pact_ex/mismatch_error.ex`
- Test: `test/pact_ex/consumer_test.exs`

**Interfaces:**
- Consumes: Native NIFs (Tasks 2–3), `PactEx.Pact` and `PactEx.HTTP.*` (Task 4), `PactEx.Matchers` (Task 5).
- Produces:
  - `PactEx.Error` exception with fields `function`, `code` and `message`, plus `from_native(map) :: t()`.
  - `PactEx.MismatchError` exception with field `mismatches :: [map()]`. `message/1` lists each mismatch's `"type"` together with `"method"`/`"path"`.
  - `%PactEx.MockServer{port: pos_integer(), url: String.t(), pact_dir: Path.t(), pact_ref: reference()}`
  - `PactEx.MockServer.matched?(t) :: boolean()`
  - `PactEx.MockServer.mismatches(t) :: [map()]` (decoded with `JSON.decode!/1`, `[]` when nil)
  - `PactEx.MockServer.write_pact(t, opts \\ [overwrite: false]) :: :ok | {:error, PactEx.Error.t()}`
  - `PactEx.MockServer.stop(t) :: :ok`
  - `PactEx.Consumer.start_mock_server(Pact.t(), [HTTP.Interaction.t()], opts \\ [host: "127.0.0.1", port: 0]) :: {:ok, MockServer.t()} | {:error, PactEx.Error.t()}`
  - `PactEx.Consumer.run(Pact.t(), [HTTP.Interaction.t()], (MockServer.t() -> any()), opts \\ []) :: :ok | {:error, PactEx.MismatchError.t() | PactEx.Error.t()}`
  - `PactEx.Consumer.run!(same args) :: :ok`, which raises the error struct.
  - `PactEx.Consumer.Apply.interaction(pact_ref, HTTP.Interaction.t()) :: :ok | {:error, PactEx.Error.t()}` (`@moduledoc false`)

- [ ] **Step 1: Write the failing tests**

```elixir
# test/pact_ex/consumer_test.exs
defmodule PactEx.ConsumerTest do
  use ExUnit.Case, async: true
  import PactEx.Matchers
  alias PactEx.{Consumer, HTTP}

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    %{pact: PactEx.new("consumer-test", "provider-test", pact_dir: dir)}
  end

  defp read_pact(dir), do: dir |> Path.join("consumer-test-provider-test.json") |> File.read!() |> JSON.decode!()

  test "GET with query, headers and matchers writes a pact with matching rules", %{pact: pact, tmp_dir: dir} do
    i =
      HTTP.interaction("get user")
      |> HTTP.given("user exists", %{"id" => "1"})
      |> HTTP.with_request(:get, "/users/1", query: %{"full" => "true"}, headers: %{"accept" => "application/json"})
      |> HTTP.will_respond_with(200, body: %{"id" => like(1), "name" => like("Ann")})

    assert :ok =
             Consumer.run(pact, [i], fn mock ->
               assert %{status: 200, body: %{"id" => 1}} =
                        Req.get!(mock.url <> "/users/1", params: [full: "true"], headers: [accept: "application/json"])
             end)

    [written] = read_pact(dir)["interactions"]
    assert [%{"name" => "user exists", "params" => %{"id" => "1"}}] = written["providerStates"]
    assert get_in(written, ["response", "matchingRules", "body", "$.id"])
  end

  test "POST with JSON request body", %{pact: pact} do
    i =
      HTTP.interaction("create user")
      |> HTTP.with_request(:post, "/users", body: %{"name" => like("Ann")})
      |> HTTP.will_respond_with(201)

    assert :ok = Consumer.run(pact, [i], fn m -> assert %{status: 201} = Req.post!(m.url <> "/users", json: %{name: "Bob"}) end)
  end

  test "raw text body keeps its content type", %{pact: pact} do
    i =
      HTTP.interaction("plain")
      |> HTTP.with_request(:get, "/txt")
      |> HTTP.will_respond_with(200, body: "<a>hi</a>", content_type: "application/xml")

    assert :ok =
             Consumer.run(pact, [i], fn m ->
               resp = Req.get!(m.url <> "/txt", decode_body: false)
               assert resp.body == "<a>hi</a>"
               assert Req.Response.get_header(resp, "content-type") |> hd() =~ "application/xml"
             end)
  end

  test "multi-valued query params and matcher header values", %{pact: pact} do
    i =
      HTTP.interaction("multi")
      |> HTTP.with_request(:get, "/search", query: %{"tag" => ["a", "b"]}, headers: %{"x-id" => regex("abc-1", "^abc-\\d+$")})
      |> HTTP.will_respond_with(200)

    assert :ok =
             Consumer.run(pact, [i], fn m ->
               Req.get!(m.url <> "/search?tag=a&tag=b", headers: [{"x-id", "abc-42"}])
             end)
  end

  test "an interaction never exercised returns a MismatchError and writes nothing", %{pact: pact, tmp_dir: dir} do
    i = HTTP.interaction("never") |> HTTP.with_request(:get, "/never") |> HTTP.will_respond_with(200)

    assert {:error, %PactEx.MismatchError{mismatches: [%{"type" => "missing-request"}]}} =
             Consumer.run(pact, [i], fn _ -> :ok end)

    refute File.exists?(Path.join(dir, "consumer-test-provider-test.json"))
  end

  test "an exception in the test function stops the server, writes nothing and re-raises", %{pact: pact, tmp_dir: dir} do
    i = HTTP.interaction("boom") |> HTTP.with_request(:get, "/boom") |> HTTP.will_respond_with(200)
    parent = self()

    assert_raise RuntimeError, "boom", fn ->
      Consumer.run(pact, [i], fn m -> send(parent, {:port, m.port}); raise "boom" end)
    end

    assert_received {:port, port}
    # Already cleaned up by run/4, so a second cleanup finds no server.
    refute PactEx.Native.cleanup_mock_server(port)
    refute File.exists?(Path.join(dir, "consumer-test-provider-test.json"))
  end

  test "spec :v3 is written into metadata", %{tmp_dir: dir} do
    pact = PactEx.new("consumer-test", "provider-test", pact_dir: dir, spec: :v3)
    i = HTTP.interaction("v3") |> HTTP.with_request(:get, "/v3") |> HTTP.will_respond_with(200)
    assert :ok = Consumer.run(pact, [i], fn m -> Req.get!(m.url <> "/v3") end)
    assert read_pact(dir)["metadata"]["pactSpecification"]["version"] == "3.0.0"
  end

  test "run!/4 raises MismatchError", %{pact: pact} do
    i = HTTP.interaction("never") |> HTTP.with_request(:get, "/never") |> HTTP.will_respond_with(200)
    assert_raise PactEx.MismatchError, fn -> Consumer.run!(pact, [i], fn _ -> :ok end) end
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/pact_ex/consumer_test.exs`
Expected: FAIL with `PactEx.Consumer.run/3 is undefined`.

- [ ] **Step 3: Implement `PactEx.Error`, `PactEx.MismatchError` and `PactEx.MockServer`** as listed in Interfaces. `stop/1` calls `cleanup_mock_server` and always returns `:ok`.

- [ ] **Step 4: Implement `PactEx.Consumer.Apply.interaction/2`**

Encoding rules (the spec pins these; the tests above exercise them):
- `given` uses `Native.given/2` when params are nil, and `Native.given_with_params/3` with `JSON.encode!(params)` otherwise.
- Path, header values, query values and status: a binary passes through, a map (matcher) is `JSON.encode!/1`d, and an integer status uses `Integer.to_string/1`.
- A list value becomes one call per element, using its index.
- Body:
  - `nil` → no call.
  - Map or list → `with_body` with `JSON.encode!/1` and content type `content_type || "application/json"`.
  - UTF-8 binary without NUL → `with_body` with `content_type || "text/plain"`.
  - Any other binary → `with_binary_body` with `content_type || "application/octet-stream"`.
- Stop at the first `{:error, map}` and return `{:error, PactEx.Error.from_native(map)}`.

- [ ] **Step 5: Implement `start_mock_server/3`, `run/4` and `run!/4`**

`start_mock_server` does the following in order: `new_pact`, `with_specification`, `Apply.interaction` for each interaction, then `create_mock_server(pact_ref, host, port, "http", nil)`. It returns a `%MockServer{url: "http://#{host}:#{port}"}`.

`run/4` behaviour. The mock server owns the mismatches JSON and frees it on cleanup, so `stop` must run last:
1. Start the server. On `{:error, e}`, return it.
2. In a single `try` block, run `fun.(mock)`, then `matched?(mock)`. If it matched, call `write_pact(mock, overwrite: false)` and use its result. If not, build `{:error, %MismatchError{mismatches: mismatches(mock)}}`.
3. `MockServer.stop(mock)` goes in the `after` clause of that same `try`. An exception from `fun` skips the matching and writing, stops the server and propagates.

- [ ] **Step 6: Run tests to verify they pass**

Run: `mix test test/pact_ex/consumer_test.exs`
Expected: PASS (8 tests).

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "feat: add consumer runner, mock server API and error types"
```

---

### Task 7: Logging

**Files:**
- Create: `native/pact_ex_nif/src/log.rs`, `lib/pact_ex/log.ex`
- Modify: `native/pact_ex_nif/src/lib.rs`, `lib/pact_ex/native.ex`
- Test: `test/pact_ex/log_test.exs`

**Interfaces:**
- Consumes: `FfiError`, `Outcome`, `last_error`, `to_cstring` (Task 2), and `PactEx.Consumer.run/4` (Task 6, used by the test).
- Produces:
  - NIF `PactEx.Native.init_logger(sink :: String.t(), level :: :off | :error | :warn | :info | :debug | :trace) :: :ok | {:error, map()}`. It calls `pactffi_logger_init`, `pactffi_logger_attach_sink` and `pactffi_logger_apply` in one NIF call. Sink strings: `"stdout"`, `"stderr"`, `"file <path>"`.
  - `PactEx.Log.init(opts \\ []) :: :ok | {:error, :already_initialized} | {:error, PactEx.Error.t()}`. Opts are `level` (default `:info`) and `sink` (`:stdout | :stderr | {:file, Path.t()}`, default `:stdout`). A native code `-1` from `pactffi_logger_apply` maps to `{:error, :already_initialized}`.

- [ ] **Step 1: Write the failing test**

The logger is global per OS process, so this module is `async: false`, and both assertions live in one test:

```elixir
# test/pact_ex/log_test.exs
defmodule PactEx.LogTest do
  use ExUnit.Case, async: false
  alias PactEx.HTTP

  @tag :tmp_dir
  test "file sink receives FFI logs and a second init is rejected", %{tmp_dir: dir} do
    log = Path.join(dir, "pact.log")
    assert PactEx.Log.init(level: :debug, sink: {:file, log}) == :ok

    pact = PactEx.new("log-consumer", "log-provider", pact_dir: dir)
    i = HTTP.interaction("logged") |> HTTP.with_request(:get, "/l") |> HTTP.will_respond_with(200)
    :ok = PactEx.Consumer.run(pact, [i], fn m -> Req.get!(m.url <> "/l") end)

    assert File.read!(log) =~ "DEBUG"
    assert PactEx.Log.init(level: :info) == {:error, :already_initialized}
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/pact_ex/log_test.exs`
Expected: FAIL with `PactEx.Log.init/1 is undefined`.

- [ ] **Step 3: Implement `log.rs`**

Map the level atom to pact_ffi's `LevelFilter`. Return `last_error("pactffi_logger_attach_sink", c)` or `last_error("pactffi_logger_apply", c)` for a negative `c`. Then implement `PactEx.Log.init/1`.

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/pact_ex/log_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat: add pact_ffi logging configuration"
```

---

### Task 8: pact_erlang parity acceptance suite and concurrent writes

**Files:**
- Create: `test/support/animal_client.ex`, `test/acceptance/http_end_to_end_test.exs`, `test/acceptance/concurrent_write_test.exs`

**Interfaces:**
- Consumes: the whole public API (Tasks 4–6).
- Produces: `AnimalClient` (test support, Req-based):
  - `get_animal(base_url, name) :: {:ok, map()} | {:error, :not_found}`
  - `create_animal(base_url, map()) :: :ok`
  - `search_animals(base_url, query :: map()) :: {:ok, map()}`

- [ ] **Step 1: Write the acceptance tests**

`http_end_to_end_test.exs` ports the four cases from pact_erlang `test/http_end_to_end_SUITE.erl`, with the same descriptions, states, bodies and matchers. All four use the consumer `"animal_service_consumer"`, the provider `"animal_service"` and a shared `tmp_dir`. Each test asserts that `Consumer.run/3` returns `:ok`. The final test asserts that the written pact has 4 interactions.
- `"a request to GET an animal: Mary"`: given `"an alligator with the name Mary exists"` with params `%{"name" => "Mary", "type" => "alligator"}`. Expects 200 with that JSON body, and the client returns `{:ok, body}`.
- `"a request to GET a non-existing animal: Miles"`: path `regex("/animals/Miles", "^\\/animals\\/[a-zA-Z]+")`. Expects 404 with `%{"error" => "not_found"}`, and the client returns `{:error, :not_found}`.
- `"a request to create an animal: Max"`: POST with the `create_animal` body (`like/1`, `regex/2`, `each_like/1`, `each_key/2`, nested as in the SUITE). The client sends the SUITE's concrete `AnimalObject` (nickname `"lazgo"`, weight `10.0`, `attributes: %{"ferocious" => false}`). Expects 201.
- `"a request to find all alligators"`: query `%{"type" => "alligator"}`. Expects 200 with `%{"animals" => [%{"name" => "Mary", "type" => "alligator"}]}`.

`concurrent_write_test.exs`:

```elixir
@tag :tmp_dir
test "parallel runs merge into one pact file", %{tmp_dir: dir} do
  pact = PactEx.new("concurrent-consumer", "concurrent-provider", pact_dir: dir)

  1..8
  |> Task.async_stream(fn n ->
    i = HTTP.interaction("req #{n}") |> HTTP.with_request(:get, "/r/#{n}") |> HTTP.will_respond_with(200)
    PactEx.Consumer.run(pact, [i], fn m -> Req.get!(m.url <> "/r/#{n}") end)
  end, max_concurrency: 8)
  |> Enum.each(fn {:ok, result} -> assert result == :ok end)

  written = dir |> Path.join("concurrent-consumer-concurrent-provider.json") |> File.read!() |> JSON.decode!()
  assert length(written["interactions"]) == 8
end
```

- [ ] **Step 2: Implement `test/support/animal_client.ex`**

Use `Req` with `retry: false`. A 404 response maps to `{:error, :not_found}`.

- [ ] **Step 3: Run the acceptance tests**

Run: `mix test test/acceptance`
Expected: PASS (5 tests). `pact_models` 1.3.17 `write_pact` takes an in-process `WRITE_LOCK` mutex plus a blocking exclusive file lock (verified 2026-10-22), so merging should be safe. If the concurrency test fails, either with fewer than 8 interactions or with `{:error, %PactEx.Error{}}`, stop and report it. Don't patch around it: the spec's assumption is wrong and the spec needs to change.

- [ ] **Step 4: Run the full suite**

Run: `mix test && mix format --check-formatted && (cd native/pact_ex_nif && cargo fmt --check && cargo clippy -- -D warnings)`
Expected: all green.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "test: port pact_erlang HTTP acceptance suite and add concurrent write test"
```

---

### Task 9: CI, precompiled NIF release pipeline and docs

**Files:**
- Create: `.github/workflows/ci.yml`, `.github/workflows/release.yml`, `README.md` (replace), `CHANGELOG.md`, `LICENSE` (MIT), `RELEASING.md`

**Interfaces:**
- Consumes: everything above.
- Produces: GitHub release assets named the way `rustler_precompiled` expects, plus `checksum-Elixir.PactEx.Native.exs` in the Hex package.

- [ ] **Step 1: Confirm the repository URL** with the user, and update `base_url` in `lib/pact_ex/native.ex` and `source_url` in `mix.exs` if it differs from the Global Constraints value.

- [ ] **Step 2: Write `ci.yml`**

- Trigger: push and pull_request.
- Matrix: `ubuntu-latest` and `macos-latest`, with OTP 27 / Elixir 1.18 and OTP 28 / Elixir 1.19.
- Steps: `erlef/setup-beam`, `dtolnay/rust-toolchain@stable`, `Swatinem/rust-cache` with `workspaces: native/pact_ex_nif`, then `mix deps.get`, `mix format --check-formatted`, `PACT_EX_BUILD=1 mix test`.

- [ ] **Step 3: Write `release.yml`**

- Trigger: tags `v*`.
- Matrix: the 6 targets × NIF `2.16` and `2.17`. Set `use-cross: true` for `aarch64-unknown-linux-gnu` and both musl targets. Use `macos-14` for `aarch64-apple-darwin`, `macos-13` for `x86_64-apple-darwin`, and `ubuntu-22.04` for the Linux targets (older glibc for wider compatibility).
- Build with `philss/rustler-precompiled-action@v1`, with `project-name: pact_ex_nif`, `project-dir: native/pact_ex_nif`, and `project-version` taken from the tag.
- Upload with `softprops/action-gh-release@v2`.

- [ ] **Step 4: Write `RELEASING.md`**

1. Bump the version in `mix.exs` and `CHANGELOG.md`.
2. Tag `vX.Y.Z` and wait for `release.yml` to finish.
3. Run `mix rustler_precompiled.download PactEx.Native --all --print`.
4. Commit the checksum file.
5. Run `mix hex.publish`.

- [ ] **Step 5: Write `README.md`**

Sections: install, quick start (the spec's API sketch), matchers table, logging, building from source (`PACT_EX_BUILD=1`, Rust 1.88+), supported platforms, and the pact_erlang parity table from the spec. List messages, plugins and the verifier as "coming in plans 2–3".

- [ ] **Step 6: Verify packaging**

Run: `mix hex.build --unpack -o /tmp/pact_ex_pkg && ls /tmp/pact_ex_pkg/native/pact_ex_nif/src && (command -v actionlint && actionlint || true)`
Expected: the package contains `lib/`, `native/pact_ex_nif/src/*.rs` and `Cargo.toml`, with no `target/`. actionlint reports no errors if it is installed.

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "ci: add test workflow, precompiled NIF release pipeline and docs"
```
