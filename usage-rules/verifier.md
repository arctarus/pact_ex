# PactEx provider verification

`PactEx.Verifier.verify/1` replays the interactions of a pact against your
provider and compares the responses. It returns `:ok` or
`{:error, %PactEx.VerificationError{}}`. `verify!/1` raises instead. The error
message lists each failing interaction. `:report` has the full report.

```elixir
PactEx.Verifier.verify(
  provider: "animal_service",
  provider_url: "http://localhost:4000",
  dirs: ["pacts"],
  state_handler: fn
    "an alligator with the name Mary exists", _params, :setup -> MyApp.Animals.put("Mary")
    _state, _params, _action -> :ok
  end
)
```

## Provider states

- `:state_handler` is a function of arity 3: state, params, action. The action is
  `:setup`, or `:teardown` with `state_change_teardown: true`. Return `:ok`,
  `{:ok, map}` or `{:error, reason}`.
- Or give `:state_change_url` to call an endpoint of your own. Giving both is an
  error.
- The handler runs in a small web server on `127.0.0.1`, **not** in the process
  that called `verify/1`. Anything bound to the test process (process
  dictionary, Mox expectations, Ecto SQL sandbox checkout) needs shared mode or
  an explicit allowance.
- The handler has the same `:request_timeout` as each provider request (5 s). A
  slower one fails the interaction.
- A handler that fails fails the interaction at once. The reason is in
  `:callback_errors` of the error.

## Message providers

```elixir
PactEx.Verifier.verify(
  provider: "weather_service",
  dirs: ["pacts"],
  message_providers: %{
    "a weather data message" => fn _provider_states ->
      {%{"temperature" => 19.5}, %{"queue" => "weather"}}
    end
  }
)
```

Each function gets the provider states and returns `{contents, metadata}` or only
the contents. `:fallback_message_provider` answers descriptions without a
function. Leave `:provider_url` at its default (`127.0.0.1`).

## Pact Broker and publishing

```elixir
PactEx.Verifier.verify(
  provider: "animal_service",
  provider_url: "http://localhost:4000",
  broker: [url: "https://broker.example.com", token: "..."],
  state_handler: &MyApp.Pacts.state/3,
  publish: true,
  provider_version: "2.0.0",
  provider_branch: "main"
)
```

- `:broker` takes `:consumer_version_selectors` (default `mainBranch` and
  `deployedOrReleased`), `:enable_pending` and `:include_wip_pacts_since`.
- `publish: true` needs `:provider_version`. Results are published only for pacts
  that came from the broker. A failed publication is only logged: `verify/1`
  still returns `:ok`.

## Plugin transports (gRPC)

```elixir
PactEx.Verifier.verify(
  provider: "grpcprovider",
  provider_url: "http://127.0.0.1:50051",
  transports: [%{protocol: "grpc", port: 50051}],
  dirs: ["pacts"]
)
```

The verifier loads the plugin named in the pact.

## Things to know

- The state handler and the message providers need the optional dependencies
  `:plug` and `:bandit`. Add them to your `deps`. Without them `verify/1` raises
  `ArgumentError` that names them.
- `no_pacts_is_error` (default `true`): a verification that ran no interaction
  fails, for any source. A missing file or directory fails either way.
- A directory source reads only the files directly in it. A file there that is
  not a pact is an error.
- The verifier prints its report to the VM's standard output from native code.
  `ExUnit.CaptureIO` does not capture it.
- Every verification stops every plugin process of the VM when it ends. Put it
  and any plugin consumer test in `async: false` modules.
- `verify/1` blocks the calling process. Every run posts an anonymous metric to
  Google Analytics and waits with no timeout. Set `PACT_DO_NOT_TRACK=true` to
  turn it off, especially in CI behind a restrictive network.
