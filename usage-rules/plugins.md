# PactEx plugins and gRPC

A [Pact plugin](https://github.com/pact-foundation/pact-plugins) adds a content
type or a transport, such as protobuf and gRPC. Plugins are OS processes.

## Declare and use

```elixir
pact =
  "grpcconsumer"
  |> PactEx.new("grpcprovider")
  |> PactEx.using_plugin("protobuf", "0.8.1")
```

- Declare every plugin with `PactEx.using_plugin/3`. A pact uses each plugin name
  once. Plugins load when a mock server or a message test starts and unload when
  it stops.
- `PactEx.Plugin.contents(content_type, description)` builds a body that a plugin
  reads. Use the result as the `:body` of an HTTP request or response, as the
  contents of an async message, or with `SyncMessage.with_plugin_contents/2`.
- Plugin contents in a pact that does not declare the plugin return
  `{:error, %PactEx.Error{code: -101}}`.
- A plugin message arrives as raw bytes. Decode it with your own protobuf module.

## Installing

- With the repo checked out: `scripts/install-protobuf-plugin.sh`. It is not in
  the Hex package.
- From Hex: `pact-plugin-cli install`, or the `install-plugin.sh` of the plugin's
  release.
- Or rely on auto-install: a missing plugin is downloaded from the pact-plugins
  index on GitHub when the test runs. That needs network access, has **no
  timeout** and each load takes at least 500 ms. Offline, it returns an error.
- `PactEx.Plugin.installed?/2` checks the plugin directory.
- Install plugins before the test run in CI, and in sandboxes without network.

## gRPC consumer

A sync message with plugin contents and `transport: "grpc"` starts the
protobuf plugin's gRPC mock server. The function gets the port in
`generated.transport.port` and the address (`"127.0.0.1:50051"`, not a URL) in
`generated.transport.address`.

```elixir
message =
  SyncMessage.new("Route guide - GetFeature")
  |> SyncMessage.given("feature 'Big Tree' exists")
  |> SyncMessage.with_plugin_contents(
    Plugin.contents("application/protobuf", %{
      "pact:proto" => Path.expand("route_guide.proto"),
      "pact:proto-service" => "RouteGuide/GetFeature",
      "pact:content-type" => "application/protobuf",
      "request" => %{"latitude" => "matching(number, 180)", "longitude" => "matching(number, 200)"},
      "response" => %{"name" => "notEmpty('Big Tree')"}
    })
  )

:ok =
  SyncMessage.run(
    pact,
    message,
    fn %{transport: %{address: address}} ->
      {:ok, channel} = GRPC.Stub.connect(address)

      try do
        {:ok, _feature} = Routeguide.RouteGuide.Stub.get_feature(channel, point)
      after
        GRPC.Stub.disconnect(channel)
      end
    end,
    transport: "grpc"
  )
```

- Use your own gRPC client (the `grpc` Hex package).
- Other options: `:host`, `:port`, `:transport_config`.
- To answer with a gRPC error, add `"responseMetadata" => %{"grpc-status" => "NOT_FOUND"}`
  to the description.
- A run with a transport returns `{:error, %PactEx.MismatchError{}}` when an
  expected request did not arrive, and writes nothing.

## Cleanup

- `Consumer.run/4`, `Message.run/4` and `SyncMessage.run/4` unload plugins when
  your function returns, raises, throws or exits.
- With `Consumer.start_mock_server/3`, call `PactEx.MockServer.stop/1` in
  `on_exit`. Garbage collection is not a fallback when the VM exits: a mock
  server still referenced then leaves its plugin process running.
- A plugin process can outlive `run/4` for a moment.

## Known limits

- **Every verification (`PactEx.Verifier.verify/1`) stops every plugin process
  of the VM.** Run plugin consumer tests and verifications in `async: false`
  modules.
- A hung plugin download blocks every plugin cleanup and every pact builder call
  in the VM.
- Plugin tests are not run on macOS in CI: the plugin driver can hang while it
  starts a plugin there.
