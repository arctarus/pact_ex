# PactEx message tests

Messages need a V4 pact, which is the default. Any other spec returns
`{:error, %PactEx.Error{}}`.

## Async messages

An event, such as a message on a queue. The test builds the message, gets it as
a provider would send it, and passes it to your handler.

```elixir
import PactEx.Matchers
alias PactEx.Message

pact = PactEx.new("animal_service", "weather_service")

message =
  Message.new("a weather data message")
  |> Message.given("weather data for animals", %{"weather" => "cold"})
  |> Message.with_contents(%{
    "temperature" => like(23.0),
    "timestamp" => "2024-03-14T10:22:13+05:30"
  })
  |> Message.with_metadata(%{"queue" => regex("weather.eu", "^weather\\.[a-z]+$")})

:ok =
  Message.run(pact, message, fn %Message.Reified{contents: contents, metadata: metadata} ->
    WeatherConsumer.handle(contents, metadata)
  end)
```

- `Message.run/4` replaces matchers with their example values and calls your
  function with a `PactEx.Message.Reified` (`:contents`, `:metadata`,
  `:content_type`).
- If the function returns, the pact is written in merge mode. If it raises,
  throws or exits, nothing is written and the exception propagates.
  `run!/4` returns `:ok` or raises the error.
- A message needs contents: a map or list (JSON, matchers allowed), a binary, or
  plugin contents.
- Metadata values are sent as JSON, so `"5"` stays a string. A value can be a
  matcher.
- For a JSON content type `contents` is the decoded JSON. For any other type it
  is the raw bytes, such as a protobuf message: decode it yourself.

## Sync messages

One request and one or more responses, such as a gRPC call.

```elixir
alias PactEx.SyncMessage

message =
  SyncMessage.new("get a user")
  |> SyncMessage.given("user 1 exists")
  |> SyncMessage.with_request(%{"id" => integer(1)})
  |> SyncMessage.will_respond_with(%{"name" => like("Ann")})

:ok =
  SyncMessage.run(pact, message, fn %SyncMessage.Generated{} = generated ->
    UserConsumer.handle(generated.request, generated.responses)
  end)
```

- `SyncMessage.run/4` works like `Message.run/4`. The function gets a
  `PactEx.SyncMessage.Generated` with `:request`, `:responses` and `:transport`.
- Each response has its own content type:
  `will_respond_with(message, contents, content_type: "text/plain")`.
- With `transport: "grpc"` (or another plugin transport), `run/4` also starts the
  plugin's mock server and checks it after your function returns. See
  `pact_ex:plugins`.
