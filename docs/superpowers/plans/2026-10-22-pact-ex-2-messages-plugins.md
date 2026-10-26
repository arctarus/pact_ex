# pact_ex — Plan 2: Messages, Plugins and gRPC Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

> **Status:** Written before plan 1 was implemented. Review this plan against the real plan 1 code (module names, NIF signatures, `Outcome`/`FfiError`, the `run/4` shape) before executing it.

**Goal:** Add async messages (pact_erlang parity), sync messages, and the Pact plugin system to `pact_ex`. That covers loading plugins, plugin-driven contents and plugin transports, with the protobuf plugin's gRPC transport as the acceptance case.

**Architecture:** New thin NIFs over the `pact_ffi` message and plugin functions, built with the plan 1 patterns: resources, `Outcome`, `clear_error`/`last_error`, and `on_large_stack` for anything that blocks or talks to a plugin. On the Elixir side:
- `PactEx.Message` (async) and `PactEx.SyncMessage` are pure builders. Each has a `run/4` that creates a fresh FFI pact, loads plugins, applies the interaction, hands the reified contents to the test function, and writes the pact.
- `PactEx.Plugin.contents/2` produces a `%PactEx.PluginContents{}` value. It works as a body in HTTP interactions, async messages and sync messages.

**Tech Stack:** Plan 1 stack, plus the protobuf plugin 0.8.1. Test only: `grpc` ~> 1.0 and `protobuf` ~> 0.17.

**Spec:** `docs/superpowers/specs/2026-10-22-pact-ex-design.md`

## Global Constraints

- Every plan 1 Global Constraint applies, including the test-coverage rule: unit tests for every new function or NIF and its error paths, plus end-to-end tests. Here end-to-end means a real `Message.run` or `SyncMessage.run`, a real gRPC client against the plugin mock server, and assertions on the written pact.
- Protobuf plugin version `0.8.1`. Install it under `${PACT_PLUGIN_DIR:-$HOME/.pact/plugins}/protobuf-0.8.1` with `scripts/install-protobuf-plugin.sh`.
- Tests that need a plugin are tagged `:plugin`, live in `async: false` modules, and are excluded unless `<plugin dir>/protobuf-0.8.1/pact-plugin.json` exists.
- Every code path that calls `using_plugin` must call `cleanup_plugins` on the same pact handle, including when the test function raises. Plugins are OS processes and survive otherwise.
- NIFs that block or may call a plugin are `DirtyIo` and run inside `on_large_stack`: `using_plugin`, `interaction_contents`, `cleanup_plugins`, `message_reify`, `sync_message_generate_contents`, `pact_handle_write_file`.
- Strings returned by `pactffi_message_reify` and `pactffi_sync_message_generate_contents` are copied into Rust `String`s and then freed with `pact_ffi::pactffi_string_delete`.
- Message pacts are written with `pactffi_pact_handle_write_file(pact, dir, false)` (merge mode).
- No `pactffi_set_test_run_id` and no plugin log callback (spec: no callbacks).

## Review Focus

1. **The test function raises during a gRPC or plugin test.** The mock server stops, `cleanup_plugins` runs, no pact is written, the exception is re-raised, and no `pact-protobuf-plugin` OS process is left behind. Tested in Task 5.
2. **The plugin is not installed.** `run/4` returns `{:error, %PactEx.Error{function: "pactffi_using_plugin", code: 2}}` with a message that names the plugin, and it does not crash or hang. Tested in Task 2. This test runs without the plugin installed.
3. **gRPC error responses.** `responseMetadata` with `grpc-status: NOT_FOUND` reaches the client as a gRPC error, not as a decoding failure. Tested in Task 5.
4. **Binary message contents.** A protobuf async message is handed to the test function as raw bytes, decoded from the V4 `{"content": ..., "encoded": "base64"}` envelope, not as a base64 string. Tested in Task 6.
5. **Message metadata given as matchers.** A metadata value given as a matcher map is JSON-encoded, recorded as a matching rule, and reified to its example value. Tested in Task 3.

---

### Task 1: Native message and plugin NIFs

**Files:**
- Create: `native/pact_ex_nif/src/messages.rs`, `native/pact_ex_nif/src/plugins.rs`
- Modify: `native/pact_ex_nif/src/lib.rs`, `lib/pact_ex/native.ex`
- Test: `test/pact_ex/native/messages_test.exs`

**Interfaces:**
- Consumes (plan 1): `FfiError`, `Outcome`, `clear_error`, `last_error`, `to_cstring`, `on_large_stack`, `PactResource`, `InteractionResource`, `Part`, and the NIFs `new_pact/2`, `with_specification/2`, `given/2`, `with_body/4`, `with_binary_body/4`.
- Produces (Elixir NIFs in `PactEx.Native`):
  - `new_message_interaction(pact, description :: String.t()) :: reference()`
  - `new_sync_message_interaction(pact, description :: String.t()) :: reference()`
  - `with_metadata(interaction, key :: String.t(), value :: String.t(), part :: :request | :response) :: :ok | {:error, map()}`
  - `message_reify(interaction) :: {:ok, String.t()} | {:error, map()}` (DirtyIo)
  - `sync_message_generate_contents(interaction) :: {:ok, String.t()} | {:error, map()}` (DirtyIo)
  - `pact_handle_write_file(pact, dir :: String.t(), overwrite :: boolean()) :: :ok | {:error, map()}` (DirtyIo)
  - `using_plugin(pact, name :: String.t(), version :: String.t() | nil) :: :ok | {:error, map()}` (DirtyIo)
  - `interaction_contents(interaction, part :: :request | :response, content_type :: String.t(), contents_json :: String.t()) :: :ok | {:error, map()}` (DirtyIo)
  - `cleanup_plugins(pact) :: :ok` (DirtyIo)

- [ ] **Step 1: Write the failing tests**

```elixir
# test/pact_ex/native/messages_test.exs
defmodule PactEx.Native.MessagesTest do
  use ExUnit.Case, async: true
  alias PactEx.Native

  defp v4_pact do
    pact = Native.new_pact("native-msg-consumer", "native-msg-provider")
    :ok = Native.with_specification(pact, :v4)
    pact
  end

  test "async message reifies with generators applied and metadata set" do
    pact = v4_pact()
    i = Native.new_message_interaction(pact, "a weather message")
    :ok = Native.given(i, "weather available")
    :ok = Native.with_body(i, :request, "application/json", ~s({"temp": {"pact:matcher:type": "type", "value": 23.0}}))
    :ok = Native.with_metadata(i, "queue", "weather", :request)

    assert {:ok, json} = Native.message_reify(i)
    reified = JSON.decode!(json)
    assert reified["contents"]["content"] == %{"temp" => 23.0}
    assert reified["metadata"]["queue"] == "weather"
  end

  test "sync message generates request and response contents" do
    pact = v4_pact()
    i = Native.new_sync_message_interaction(pact, "a sync message")
    :ok = Native.with_body(i, :request, "application/json", ~s({"id": 1}))
    :ok = Native.with_body(i, :response, "application/json", ~s({"name": "Ann"}))

    assert {:ok, json} = Native.sync_message_generate_contents(i)
    generated = JSON.decode!(json)
    assert generated["request"]["contents"]["content"] == %{"id" => 1}
    assert [%{"contents" => %{"content" => %{"name" => "Ann"}}}] = generated["response"]
  end

  @tag :tmp_dir
  test "message pacts are written by pact handle", %{tmp_dir: dir} do
    pact = v4_pact()
    i = Native.new_message_interaction(pact, "written message")
    :ok = Native.with_body(i, :request, "application/json", ~s({"a": 1}))
    assert Native.pact_handle_write_file(pact, dir, false) == :ok
    written = dir |> Path.join("native-msg-consumer-native-msg-provider.json") |> File.read!() |> JSON.decode!()
    assert [%{"type" => "Asynchronous/Messages"}] = written["interactions"]
  end

  test "loading a plugin that is not installed returns code 2 with a message" do
    pact = v4_pact()

    assert {:error, %{function: "pactffi_using_plugin", code: 2, message: message}} =
             Native.using_plugin(pact, "pact-ex-no-such-plugin", "9.9.9")

    assert message =~ "pact-ex-no-such-plugin"
    assert Native.cleanup_plugins(pact) == :ok
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/pact_ex/native/messages_test.exs`
Expected: FAIL with `PactEx.Native.new_message_interaction/2 is undefined or private`.

- [ ] **Step 3: Implement `messages.rs`**

- `new_message_interaction` and `new_sync_message_interaction` wrap the returned `InteractionHandle` in an `InteractionResource`, the same way plan 1 `new_interaction` does.
- `with_metadata` calls `pactffi_with_metadata(handle, key, value, part)`. A `false` return maps to `last_error("pactffi_with_metadata", 1)`.
- `message_reify` needs a `MessageHandle`, but we hold an `InteractionHandle`. Both are `#[repr(transparent)]` over a `u32` with the same `(pact_ref << 16) | index` packing (`mock_server/handles.rs`, `InteractionHandle::new` and `MessageHandle::new_v4`). Convert with `std::mem::transmute::<InteractionHandle, MessageHandle>` and keep a `// SAFETY:` comment that cites that packing.
- An empty returned string maps to `last_error("pactffi_message_reify", 1)`. Free the returned pointer with `pactffi_string_delete`.
- `sync_message_generate_contents` follows the same rules (empty string → error, and free the pointer).
- `pact_handle_write_file` maps a non-zero code `c` to `last_error("pactffi_pact_handle_write_file", c)`.

- [ ] **Step 4: Implement `plugins.rs`**

- `using_plugin` calls `pactffi_using_plugin` with a null pointer when `version` is `nil`. A non-zero code `c` maps to `last_error("pactffi_using_plugin", c)`.
- `interaction_contents` calls `pactffi_interaction_contents`. A non-zero code `c` maps to `last_error("pactffi_interaction_contents", c)`.
- `cleanup_plugins` calls `pactffi_cleanup_plugins` and returns `:ok`.

- [ ] **Step 5: Run tests to verify they pass**

Run: `mix test test/pact_ex/native/messages_test.exs`
Expected: PASS (4 tests). The last test runs without any plugin installed.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "feat(native): add message, sync message and plugin NIFs"
```

---

### Task 2: Plugin support in the data model and the HTTP consumer

**Files:**
- Create: `lib/pact_ex/plugin.ex`, `lib/pact_ex/plugin_contents.ex`, `scripts/install-protobuf-plugin.sh`, `test/fixtures/route_guide.proto`
- Modify: `lib/pact_ex/pact.ex`, `lib/pact_ex.ex`, `lib/pact_ex/consumer.ex`, `lib/pact_ex/consumer/apply.ex`, `lib/pact_ex/mock_server.ex`, `test/test_helper.exs`
- Test: `test/pact_ex/plugin_test.exs`

**Interfaces:**
- Consumes: Task 1 NIFs, and the plan 1 `PactEx.Consumer` and `PactEx.MockServer`.
- Produces:
  - `%PactEx.Pact{}` gains `plugins: [{String.t(), String.t() | nil}]` (default `[]`).
  - `PactEx.using_plugin(pact, name, version \\ nil) :: Pact.t()` appends to `plugins`.
  - `%PactEx.PluginContents{content_type: String.t(), contents: map()}`
  - `PactEx.Plugin.contents(content_type, contents :: map()) :: PluginContents.t()`
  - `PactEx.Plugin.load_all(pact_ref, Pact.t()) :: :ok | {:error, PactEx.Error.t()}` calls `Native.using_plugin/3` for each plugin in order.
  - `PactEx.Plugin.cleanup(pact_ref) :: :ok`
  - `PactEx.Plugin.installed?(name, version) :: boolean()` checks `<plugin dir>/<name>-<version>/pact-plugin.json`. The plugin dir is `$PACT_PLUGIN_DIR` or `~/.pact/plugins`.
  - `Apply.interaction/2` handles a `%PluginContents{}` body with `Native.interaction_contents(i, part, content_type, JSON.encode!(contents))`.
  - `start_mock_server/3` calls `Plugin.load_all/2` before applying interactions. On any later failure it calls `Plugin.cleanup/1` before returning the error. `MockServer.stop/1` calls `Plugin.cleanup(pact_ref)` after `cleanup_mock_server`.
  - A new `transport` option in `start_mock_server/3` and `run/4`, with default `"http"`.

- [ ] **Step 1: Write the install script and test helper exclusion**

`scripts/install-protobuf-plugin.sh` (bash, `set -euo pipefail`):
- `VERSION=0.8.1` and `DIR="${PACT_PLUGIN_DIR:-$HOME/.pact/plugins}/protobuf-$VERSION"`.
- Map `uname -s`/`uname -m` to `linux|macos` × `x86_64|aarch64`. Map `arm64` to `aarch64`.
- Download with `curl -fsSL` from `https://github.com/pactflow/pact-protobuf-plugin/releases/download/v-$VERSION/`: `pact-plugin.json` and `pact-protobuf-plugin-<os>-<arch>.gz`.
- Gunzip to `$DIR/pact-protobuf-plugin` and `chmod +x` it.
- Exit 0 without doing anything if `$DIR/pact-plugin.json` already exists.

In `test/test_helper.exs`, call `ExUnit.start(exclude: if(PactEx.Plugin.installed?("protobuf", "0.8.1"), do: [], else: [:plugin]))`.

Copy `route_guide.proto` from pact-go `examples/grpc/routeguide/route_guide.proto` into `test/fixtures/` and keep its license header.

- [ ] **Step 2: Write the failing tests**

```elixir
# test/pact_ex/plugin_test.exs
defmodule PactEx.PluginTest do
  use ExUnit.Case, async: false
  alias PactEx.{Consumer, HTTP, Plugin}

  test "using_plugin/3 accumulates plugins in order" do
    pact = PactEx.new("c", "p") |> PactEx.using_plugin("protobuf", "0.8.1") |> PactEx.using_plugin("csv")
    assert pact.plugins == [{"protobuf", "0.8.1"}, {"csv", nil}]
  end

  test "contents/2 builds a PluginContents value" do
    assert %PactEx.PluginContents{content_type: "application/protobuf", contents: %{"a" => 1}} =
             Plugin.contents("application/protobuf", %{"a" => 1})
  end

  test "a missing plugin fails start_mock_server with a clear error" do
    pact = PactEx.new("c", "p") |> PactEx.using_plugin("pact-ex-no-such-plugin", "9.9.9")
    i = HTTP.interaction("x") |> HTTP.with_request(:get, "/x") |> HTTP.will_respond_with(200)

    assert {:error, %PactEx.Error{function: "pactffi_using_plugin", code: 2}} =
             Consumer.start_mock_server(pact, [i])
  end

  @tag :plugin
  @tag :tmp_dir
  test "HTTP response with a protobuf body via the plugin", %{tmp_dir: dir} do
    proto = Path.expand("../fixtures/route_guide.proto", __DIR__)
    pact = PactEx.new("plugin-http-consumer", "plugin-http-provider", pact_dir: dir) |> PactEx.using_plugin("protobuf", "0.8.1")

    body =
      Plugin.contents("application/protobuf", %{
        "pact:proto" => proto,
        "pact:message-type" => "Feature",
        "pact:content-type" => "application/protobuf",
        "name" => "notEmpty('Big Tree')"
      })

    i = HTTP.interaction("get feature") |> HTTP.with_request(:get, "/feature") |> HTTP.will_respond_with(200, body: body)

    assert :ok =
             Consumer.run(pact, [i], fn m ->
               resp = Req.get!(m.url <> "/feature", decode_body: false)
               assert %Routeguide.Feature{name: "Big Tree"} = Routeguide.Feature.decode(resp.body)
             end)
  end
end
```

The last test needs `Routeguide.Feature`, which Task 5 creates. Until then, keep it tagged and also add `@tag :skip`. Task 5 removes that `@tag :skip`.

- [ ] **Step 3: Run tests to verify they fail**

Run: `mix test test/pact_ex/plugin_test.exs`
Expected: FAIL with `PactEx.using_plugin/2 is undefined`.

- [ ] **Step 4: Implement everything listed in Interfaces**

- [ ] **Step 5: Run tests to verify they pass, and that plan 1 still passes**

Run: `mix test`
Expected: PASS (the plugin test is skipped).

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "feat: add plugin loading and plugin contents for HTTP interactions"
```

---

### Task 3: Async messages (pact_erlang parity)

**Files:**
- Create: `lib/pact_ex/message.ex`, `lib/pact_ex/message/reified.ex`, `lib/pact_ex/message/runner.ex`
- Test: `test/pact_ex/message_test.exs`, `test/acceptance/message_end_to_end_test.exs`

**Interfaces:**
- Consumes: Task 1 NIFs, the Task 2 `Plugin.load_all/2`, `Plugin.cleanup/1` and `PluginContents`, plan 1 `PactEx.Error`, and plan 1 body encoding in `PactEx.Consumer.Apply` (reuse the body rules, don't duplicate them).
- Produces:
  - `%PactEx.Message{description: String.t(), provider_states: [{String.t(), map() | nil}], contents: term(), content_type: String.t() | nil, metadata: %{String.t() => term()}}`
  - `PactEx.Message.new(description) :: t()`
  - `PactEx.Message.given(msg, state, params \\ nil) :: t()`
  - `PactEx.Message.with_contents(msg, contents, opts \\ []) :: t()` with the opt `content_type`. `contents` may be a map/list (JSON), a binary or a `%PluginContents{}`.
  - `PactEx.Message.with_metadata(msg, map) :: t()` merges into `metadata`.
  - `%PactEx.Message.Reified{contents: term(), metadata: map(), content_type: String.t() | nil}`. `contents` is decoded JSON for JSON content types and raw bytes otherwise.
  - `PactEx.Message.run(Pact.t(), t(), (Reified.t() -> any()), opts \\ []) :: :ok | {:error, PactEx.Error.t()}`
  - `PactEx.Message.run!(...) :: :ok`

- [ ] **Step 1: Write the failing tests**

```elixir
# test/pact_ex/message_test.exs
defmodule PactEx.MessageTest do
  use ExUnit.Case, async: true
  import PactEx.Matchers
  alias PactEx.Message

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    %{pact: PactEx.new("msg-consumer", "msg-provider", pact_dir: dir)}
  end

  defp read_pact(dir), do: dir |> Path.join("msg-consumer-msg-provider.json") |> File.read!() |> JSON.decode!()

  test "JSON message with matchers and metadata is reified and written", %{pact: pact, tmp_dir: dir} do
    msg =
      Message.new("a weather data message")
      |> Message.given("weather data for animals", %{"weather" => "cold"})
      |> Message.with_contents(%{"temperature" => like(23.0), "timestamp" => "2024-03-14T10:22:13+05:30"})
      |> Message.with_metadata(%{"queue" => regex("weather.eu", "^weather\\.[a-z]+$")})

    assert :ok =
             Message.run(pact, msg, fn %Message.Reified{contents: contents, metadata: metadata} ->
               assert contents == %{"temperature" => 23.0, "timestamp" => "2024-03-14T10:22:13+05:30"}
               assert metadata["queue"] == "weather.eu"
             end)

    [written] = read_pact(dir)["interactions"]
    assert written["type"] == "Asynchronous/Messages"
    assert written["matchingRules"]["metadata"]["queue"]
    assert [%{"name" => "weather data for animals", "params" => %{"weather" => "cold"}}] = written["providerStates"]
  end

  test "an exception in the handler writes nothing and re-raises", %{pact: pact, tmp_dir: dir} do
    msg = Message.new("boom") |> Message.with_contents(%{"a" => 1})
    assert_raise RuntimeError, "boom", fn -> Message.run(pact, msg, fn _ -> raise "boom" end) end
    refute File.exists?(Path.join(dir, "msg-consumer-msg-provider.json"))
  end

  test "plain text contents keep their content type", %{pact: pact} do
    msg = Message.new("text") |> Message.with_contents("hello", content_type: "text/plain")

    assert :ok =
             Message.run(pact, msg, fn r ->
               assert r.contents == "hello"
               assert r.content_type =~ "text/plain"
             end)
  end
end
```

`test/acceptance/message_end_to_end_test.exs` ports pact_erlang `message_end_to_end_SUITE` `animal_consume_message_1..4`, with the same descriptions, states, params and the `like/1` weather body. It uses the consumer `"animal_service"` and the provider `"weather_service"` in a shared `tmp_dir`. Each test calls `Message.run/3` with a handler that asserts the reified `weather.temperature == 23.0`. The last test asserts that the written pact has 4 interactions.

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/pact_ex/message_test.exs`
Expected: FAIL with `PactEx.Message.new/1 is undefined`.

- [ ] **Step 3: Implement `PactEx.Message` and `PactEx.Message.Runner`**

`run/4` does the following:
1. `new_pact` and `with_specification`.
2. `Plugin.load_all`.
3. `new_message_interaction`, then the `given` calls.
4. Contents via the shared body rules. `%PluginContents{}` goes through `interaction_contents(i, :request, ...)`.
5. One `with_metadata(i, k, encode(v), :request)` per metadata entry, where `encode` follows plan 1's value encoding (binary passes through, map → `JSON.encode!`).
6. `message_reify`, then decode into `%Reified{}`. For a V4 body envelope `%{"content" => c, "contentType" => ct, "encoded" => enc}`: when `enc == "base64"`, use `Base.decode64!(c)`. When `enc` is `false` or `"json"`, use `c` as is.
7. Call `fun.(reified)`.
8. On normal return, `pact_handle_write_file(pact_ref, pact_dir, false)`.
9. `Plugin.cleanup(pact_ref)` in `after`.

An exception from `fun` propagates without writing.

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test test/pact_ex/message_test.exs test/acceptance/message_end_to_end_test.exs`
Expected: PASS (7 tests).

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat: add async message consumer with pact_erlang parity suite"
```

---

### Task 4: Sync messages without a transport

**Files:**
- Create: `lib/pact_ex/sync_message.ex`, `lib/pact_ex/sync_message/generated.ex`, `lib/pact_ex/sync_message/runner.ex`
- Test: `test/pact_ex/sync_message_test.exs`

**Interfaces:**
- Consumes: Task 1 NIFs, Task 2 plugin functions, the Task 3 envelope decoding (extract it to a shared private helper, e.g. `PactEx.Message.Reified.decode_contents/1`, and reuse it here).
- Produces:
  - `%PactEx.SyncMessage{description: String.t(), provider_states: [...], request: term(), request_content_type: String.t() | nil, responses: [term()], response_content_type: String.t() | nil, plugin_contents: PluginContents.t() | nil}`
  - `PactEx.SyncMessage.new(description) :: t()`
  - `PactEx.SyncMessage.given(sm, state, params \\ nil) :: t()`
  - `PactEx.SyncMessage.with_request(sm, contents, opts \\ []) :: t()` with the opt `content_type`.
  - `PactEx.SyncMessage.will_respond_with(sm, contents, opts \\ []) :: t()` appends to `responses`, with the opt `content_type`.
  - `PactEx.SyncMessage.with_plugin_contents(sm, PluginContents.t()) :: t()` sets the whole request/response definition through the plugin, as pact-go `WithContents` does.
  - `%PactEx.SyncMessage.Generated{request: term(), responses: [term()], transport: %{port: pos_integer(), url: String.t()} | nil}`
  - `PactEx.SyncMessage.run(Pact.t(), t(), (Generated.t() -> any()), opts \\ []) :: :ok | {:error, PactEx.Error.t() | PactEx.MismatchError.t()}` with the opts `transport` (default `nil`), `host` (default `"127.0.0.1"`), `port` (default `0`) and `transport_config` (map, default `nil`).
  - `PactEx.SyncMessage.run!(...) :: :ok`

- [ ] **Step 1: Write the failing tests**

```elixir
# test/pact_ex/sync_message_test.exs
defmodule PactEx.SyncMessageTest do
  use ExUnit.Case, async: true
  import PactEx.Matchers
  alias PactEx.SyncMessage

  @moduletag :tmp_dir

  test "JSON request/response sync message is generated and written", %{tmp_dir: dir} do
    pact = PactEx.new("sync-consumer", "sync-provider", pact_dir: dir)

    sm =
      SyncMessage.new("get user")
      |> SyncMessage.given("user 1 exists")
      |> SyncMessage.with_request(%{"id" => integer(1)})
      |> SyncMessage.will_respond_with(%{"name" => like("Ann")})

    assert :ok =
             SyncMessage.run(pact, sm, fn %SyncMessage.Generated{request: req, responses: [resp], transport: nil} ->
               assert req == %{"id" => 1}
               assert resp == %{"name" => "Ann"}
             end)

    written = dir |> Path.join("sync-consumer-sync-provider.json") |> File.read!() |> JSON.decode!()
    assert [%{"type" => "Synchronous/Messages"}] = written["interactions"]
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/pact_ex/sync_message_test.exs`
Expected: FAIL with `PactEx.SyncMessage.new/1 is undefined`.

- [ ] **Step 3: Implement `PactEx.SyncMessage` and its runner for `transport: nil`**

The order is `new_pact`, `with_specification(:v4)`, `Plugin.load_all`, `new_sync_message_interaction`, then the `given` calls. Then either:
- `interaction_contents(i, :request, ct, JSON.encode!(contents))` when `plugin_contents` is set, or
- request contents via the shared body rules on `:request`, and each response on `:response`.

Then `sync_message_generate_contents`, decode both envelopes, call `fun`, write with `pact_handle_write_file`, and `Plugin.cleanup` in `after`. The transport path comes in Task 5. Until then, if `transport` is set, raise `ArgumentError, "transport support lands in Task 5"`. Task 5 removes that line.

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/pact_ex/sync_message_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat: add synchronous message consumer"
```

---

### Task 5: gRPC transport via the protobuf plugin

**Files:**
- Create: `test/support/route_guide.ex` (handwritten `Protobuf` and `GRPC` modules)
- Modify: `mix.exs` (test deps `{:grpc, "~> 1.0", only: :test}` and `{:protobuf, "~> 0.17", only: :test}`), `lib/pact_ex/sync_message/runner.ex`, `test/pact_ex/plugin_test.exs` (remove `@tag :skip`)
- Test: `test/acceptance/grpc_consumer_test.exs`

**Interfaces:**
- Consumes: Task 4 `SyncMessage.run/4`, the plan 1 NIFs `create_mock_server/5`, `mock_server_matched/1`, `mock_server_mismatches/1`, `write_pact_file/3` and `cleanup_mock_server/1`, and plan 1 `PactEx.MismatchError`.
- Produces:
  - `SyncMessage.run/4` with `transport: "grpc"` (or any plugin transport name).
  - Test support modules: `Routeguide.Point` (`latitude` int32 = 1, `longitude` int32 = 2), `Routeguide.Feature` (`name` string = 1, `location` `Routeguide.Point` = 2), `Routeguide.RouteGuide.Service` (`name: "routeguide.RouteGuide"`, `rpc :GetFeature, Routeguide.Point, Routeguide.Feature`) and `Routeguide.RouteGuide.Stub`. Plan 3 reuses these for the provider side.

- [ ] **Step 1: Write the failing tests**

```elixir
# test/acceptance/grpc_consumer_test.exs
defmodule PactEx.Acceptance.GrpcConsumerTest do
  use ExUnit.Case, async: false
  alias PactEx.{Plugin, SyncMessage}

  @moduletag :plugin
  @moduletag :tmp_dir
  @proto Path.expand("../fixtures/route_guide.proto", __DIR__)

  setup %{tmp_dir: dir} do
    pact = PactEx.new("grpcconsumer", "grpcprovider", pact_dir: dir) |> PactEx.using_plugin("protobuf", "0.8.1")
    %{pact: pact}
  end

  defp get_feature(contents) do
    SyncMessage.new("Route guide - GetFeature")
    |> SyncMessage.given("feature 'Big Tree' exists")
    |> SyncMessage.with_plugin_contents(
      Plugin.contents("application/protobuf", Map.merge(%{"pact:proto" => @proto, "pact:proto-service" => "RouteGuide/GetFeature", "pact:content-type" => "application/protobuf"}, contents))
    )
  end

  defp call(port, point) do
    {:ok, channel} = GRPC.Stub.connect("127.0.0.1:#{port}")
    try do
      Routeguide.RouteGuide.Stub.get_feature(channel, point)
    after
      GRPC.Stub.disconnect(channel)
    end
  end

  test "GetFeature success writes a gRPC pact", %{pact: pact, tmp_dir: dir} do
    sm =
      get_feature(%{
        "request" => %{"latitude" => "matching(number, 180)", "longitude" => "matching(number, 200)"},
        "response" => %{"name" => "notEmpty('Big Tree')", "location" => %{"latitude" => "matching(number, 180)", "longitude" => "matching(number, 200)"}}
      })

    assert :ok =
             SyncMessage.run(pact, sm, fn %{transport: %{port: port}} ->
               assert {:ok, %Routeguide.Feature{name: "Big Tree"}} = call(port, %Routeguide.Point{latitude: 180, longitude: 200})
             end, transport: "grpc")

    written = dir |> Path.join("grpcconsumer-grpcprovider.json") |> File.read!() |> JSON.decode!()
    assert [%{"name" => "protobuf", "version" => "0.8.1"}] = written["metadata"]["plugins"]
  end

  test "NOT_FOUND response metadata reaches the client as a gRPC error", %{pact: pact} do
    sm =
      get_feature(%{
        "request" => %{"latitude" => "matching(number, -1)", "longitude" => "matching(number, -1)"},
        "responseMetadata" => %{"grpc-status" => "NOT_FOUND", "grpc-message" => "matching(type, 'no feature was found')"}
      })

    assert :ok =
             SyncMessage.run(pact, sm, fn %{transport: %{port: port}} ->
               assert {:error, %GRPC.RPCError{status: 5}} = call(port, %Routeguide.Point{latitude: -1, longitude: -1})
             end, transport: "grpc")
  end

  test "a gRPC interaction never called returns MismatchError", %{pact: pact} do
    sm = get_feature(%{"request" => %{"latitude" => "matching(number, 1)"}, "response" => %{"name" => "notEmpty('x')"}})

    assert {:error, %PactEx.MismatchError{mismatches: [%{"path" => path, "error" => error}]} = mismatch} =
             SyncMessage.run(pact, sm, fn _ -> :ok end, transport: "grpc")

    # Confirmed in the plugin source (spike S1, see the note after this block).
    assert path =~ "RouteGuide/GetFeature"
    assert error =~ "Did not receive any requests for path"
    assert Exception.message(mismatch) =~ "RouteGuide/GetFeature: Did not receive any requests"
  end

  test "an exception stops the server, cleans plugins and leaves no plugin process", %{pact: pact} do
    sm = get_feature(%{"request" => %{"latitude" => "matching(number, 1)"}, "response" => %{"name" => "notEmpty('x')"}})
    assert_raise RuntimeError, fn -> SyncMessage.run(pact, sm, fn _ -> raise "boom" end, transport: "grpc") end
    # Plugin shutdown is asynchronous; poll for up to 5 s.
    assert Enum.any?(1..50, fn _ -> Process.sleep(100); System.cmd("pgrep", ["-f", "pact-protobuf-plugin"]) |> elem(1) == 1 end)
  end
end
```

**How the plugin reports a call that never came (spike S1, read from source; not run against the installed plugin).** The protobuf plugin 0.8.1 does report it, so the "never called" test above is expected to pass as written.
- At server start the plugin registers every route as `(0 requests, no results)` (`pact-protobuf-plugin` tag `v-0.8.1`, `src/mock_server.rs:204-209`). The route key is `/<package>.<Service>/<Method>`, here `/routeguide.RouteGuide/GetFeature` (`build_grpc_route`, `src/utils.rs:624-637`).
- `GetMockServerResults` (`src/server.rs:860-871`) builds one `MockServerResult` per route (`get_mock_server_results`, `src/server.rs:116-190`). A route with 0 requests gets `path` = the route and `error` = `"Did not receive any requests for path '<route>'"`. A route that got requests gets `error` = `""` and one `mismatches` entry per body or metadata mismatch (`path`, `mismatch`, `expected`, `actual`). The upstream test `tests/mock_server_tests.rs:49-62` asserts this message for an uncalled route.
- `ok` is true only if every route got at least one request and none mismatched (`src/server.rs:119-124`).
- pact-plugin-driver 1.2.6 (`src/plugin_manager.rs:774-830`) returns `[]` when `ok` is true and otherwise returns all results, including routes that matched. pact_mock_server 2.2.6 (`src/server_manager.rs:536-558`, `560-603`) uses `[] == matched` and turns each result into `{"path","error","mismatches":[{expected,actual,mismatch,path,diff}]}`. `PactEx.MismatchError` prints that as `path: error` plus each `mismatch` text, and `PactEx.Consumer.verdict/2` gives `{:error, %PactEx.Error{code: -102}}` only when it is not matched and the list is empty (an RPC failure to the plugin).
- Consequences for the code in this task: when one of several routes fails, the error lists every route. The ones that matched appear as a bare path with no error text. The plugin records a result only when it can compare the request (`src/mock_service.rs:83-96`). A request it cannot compare is answered with `FAILED_PRECONDITION` or `INVALID_ARGUMENT` and not recorded, so that route shows as "Did not receive any requests".

- [ ] **Step 2: Run tests to verify they fail**

Run: `scripts/install-protobuf-plugin.sh && mix test test/acceptance/grpc_consumer_test.exs`
Expected: FAIL with `ArgumentError: transport support lands in Task 5` (the `Routeguide` modules are not defined yet, so compilation fails first. Create the empty file in Step 3 before re-running).

- [ ] **Step 3: Write `test/support/route_guide.ex`** with `use Protobuf, syntax: :proto3`, `use GRPC.Service` and `use GRPC.Stub`, with the fields and RPC listed in Interfaces. Package `routeguide`.

- [ ] **Step 4: Implement the transport branch of `SyncMessage.run/4`**

When `transport` is set:
1. After applying the interaction, call `create_mock_server(pact_ref, host, port, transport, transport_config && JSON.encode!(transport_config))`.
2. Build `%Generated{transport: %{port: p, url: "#{host}:#{p}"}}`. Fill `request` and `responses` from `sync_message_generate_contents`.
3. Run `fun`, then check `mock_server_matched`.
4. If it matched, `write_pact_file(p, pact_dir, false)`. If not, return `{:error, %MismatchError{mismatches: decoded mismatches}}`.
5. In one `after`: `cleanup_mock_server(p)`, then `Plugin.cleanup(pact_ref)`.

The order is the same as plan 1 `run/4`: read mismatches before cleanup. Remove the Task 4 `ArgumentError` line.

- [ ] **Step 5: Run tests to verify they pass**

Run: `mix test test/acceptance/grpc_consumer_test.exs test/pact_ex/plugin_test.exs`
Expected: PASS (4 + 4 tests).

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "feat: add gRPC mock transport via the protobuf plugin"
```

---

### Task 6: Protobuf async messages via the plugin

**Files:**
- Test: `test/acceptance/protobuf_message_test.exs`
- Modify (only if the test exposes a gap): `lib/pact_ex/message/runner.ex`

**Interfaces:**
- Consumes: Task 3 `Message.run/4` with `%PluginContents{}`, and the Task 5 `Routeguide.Feature`.
- Produces: nothing new. This task proves Review Focus #4.

- [ ] **Step 1: Write the test**

```elixir
# test/acceptance/protobuf_message_test.exs
defmodule PactEx.Acceptance.ProtobufMessageTest do
  use ExUnit.Case, async: false
  alias PactEx.{Message, Plugin}

  @moduletag :plugin
  @moduletag :tmp_dir

  test "protobuf message contents arrive as raw bytes", %{tmp_dir: dir} do
    proto = Path.expand("../fixtures/route_guide.proto", __DIR__)
    pact = PactEx.new("protobuf-msg-consumer", "protobuf-msg-provider", pact_dir: dir) |> PactEx.using_plugin("protobuf", "0.8.1")

    msg =
      Message.new("feature message")
      |> Message.with_contents(
        Plugin.contents("application/protobuf", %{
          "pact:proto" => proto,
          "pact:message-type" => "Feature",
          "pact:content-type" => "application/protobuf",
          "name" => "notEmpty('Big Tree')"
        })
      )

    assert :ok =
             Message.run(pact, msg, fn %Message.Reified{contents: bytes} ->
               assert is_binary(bytes)
               assert %Routeguide.Feature{name: "Big Tree"} = Routeguide.Feature.decode(bytes)
             end)
  end
end
```

- [ ] **Step 2: Run it**

Run: `mix test test/acceptance/protobuf_message_test.exs`
Expected: PASS. If it fails because `contents` is a base64 string, fix the envelope decoding in `Message.Reified` (Task 3, Step 3 rule) and re-run.

- [ ] **Step 3: Commit**

```bash
git add -A
git commit -m "test: cover protobuf async messages via the plugin"
```

---

### Task 7: CI and docs for messages and plugins

**Files:**
- Modify: `.github/workflows/ci.yml`, `README.md`, `CHANGELOG.md`

**Interfaces:**
- Consumes: everything above.
- Produces: CI that runs the `:plugin` tests on Linux and macOS.

- [ ] **Step 1: Update `ci.yml`**

Add a step before `mix test` that runs `scripts/install-protobuf-plugin.sh`. Add a final step `pgrep -f pact-protobuf-plugin && exit 1 || true`, which fails the job if a plugin process survived the suite.

- [ ] **Step 2: Update `README.md`**

Add these sections:
- Async messages, with the weather example.
- Sync messages.
- Plugins: installing them (the script, `PACT_PLUGIN_DIR`), using them (`PactEx.using_plugin/3`, `PactEx.Plugin.contents/2`), and the gRPC example from Task 5.
- The cleanup guarantee.

Update the parity table rows for plan 2.

- [ ] **Step 3: Verify**

Run: `mix test && mix format --check-formatted && (cd native/pact_ex_nif && cargo fmt --check && cargo clippy -- -D warnings)`
Expected: all green, with plugin tests included when the plugin is installed.

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "ci: run plugin tests and document messages and plugins"
```
