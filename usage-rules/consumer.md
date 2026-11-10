# PactEx HTTP consumer tests

## Shape of a test

```elixir
import PactEx.Matchers

pact = PactEx.new("web", "user_service", pact_dir: "pacts")

interaction =
  PactEx.HTTP.interaction("get user by id")
  |> PactEx.HTTP.given("user exists", %{"id" => "123"})
  |> PactEx.HTTP.with_request(:get, "/users/123", headers: %{"accept" => "application/json"})
  |> PactEx.HTTP.will_respond_with(200, body: %{"id" => like(123), "name" => like("John")})

:ok =
  PactEx.Consumer.run(pact, [interaction], fn mock ->
    {:ok, _user} = UserClient.get(mock.url, "123")
  end)
```

`PactEx.Consumer.run/4` starts a mock server on `127.0.0.1` with an OS-assigned
port and calls your function with a `PactEx.MockServer`. Point your client at
`mock.url`. Options are `:host` and `:port`.

| Outcome | Result |
|---|---|
| Everything matched | Writes `<pact_dir>/<consumer>-<provider>.json` (merge mode), returns `:ok` |
| A request did not arrive, or an unexpected one did | `{:error, %PactEx.MismatchError{}}`, writes nothing. `:mismatches` has the details |
| Your function raises, throws or exits | Server stopped, nothing written, the exception propagates |
| Server could not start, or pact could not be written | `{:error, %PactEx.Error{}}` |
| Failed match with no details (plugin server did not answer) | `{:error, %PactEx.Error{code: -102}}` |

`run!/4` returns `:ok` or raises the error.

## Manual control

Only when `run/4` is not enough:

```elixir
{:ok, mock} = PactEx.Consumer.start_mock_server(pact, interactions)
on_exit(fn -> PactEx.MockServer.stop(mock) end)
```

Then `PactEx.MockServer.matched?/1`, `mismatches/1`, `write_pact/2`.

- Stop the server in `on_exit`, right after you start it, and nowhere else.
  `stop/1` stops by port: a second call can stop another test's server that got
  the same port.
- A brutal kill of the test process (ExUnit timeout) skips the cleanup.

## Request and response options

- `with_request(interaction, method, path, opts)`: `method` is an atom such as
  `:get`. Options: `:query`, `:headers`, `:body`, `:content_type`.
- `will_respond_with(interaction, status, opts)`: `:headers`, `:body`,
  `:content_type`.
- `given(interaction, state, params \\ nil)`: the provider state, with optional
  params.

## Query and headers

Names are strings or atoms. Values are strings, numbers, booleans, matchers or
lists. Numbers and booleans become strings. A list gives a multi-valued entry.

```elixir
PactEx.HTTP.with_request(interaction, :get, "/animals",
  query: %{"tag" => ["a", "b"], limit: 10, active: true},
  headers: %{"x-request-id" => regex("abc-1", "[a-z]+-\\d+")}
)
```

- `query:` and `headers:` also take a keyword list or a list of `{name, value}`
  tuples. A repeated name collects all its values in order. A map is never merged.
- Header names are case-insensitive. An atom header name is written like Req
  does: `x_request_id:` becomes `x-request-id`, `content_type:` becomes
  `Content-Type`. Query names are not changed.
- `nil`, an empty list (`"tag" => []`) or any other type returns
  `{:error, %PactEx.Error{}}`. Anything that is not a map, keyword list or
  `{name, value}` list raises `ArgumentError`.

## Bodies

| You pass | Default content type | Sent as |
|---|---|---|
| A map or list | `application/json` | JSON |
| A UTF-8 string | `text/plain` | Text, byte for byte |
| A binary that is not valid UTF-8 or has NUL bytes | `application/octet-stream` | Binary |

The content type is the `:content_type` option, else the `Content-Type` header,
else the default of the body type. Any other body type returns
`{:error, %PactEx.Error{}}`.

- Do not pass an empty or whitespace-only `Content-Type` value, nor a matcher or
  list that turns into an empty list: they return an error.
- Keep the header and `:content_type` consistent. The header is sent as written.

### XML and form bodies

With an XML content type (`application/xml`, `text/xml`, `+xml` suffixes) or
`application/x-www-form-urlencoded`, a map body is a **description** of the
body, not the body itself.

```elixir
PactEx.HTTP.will_respond_with(interaction, 200,
  headers: %{"Content-Type" => "application/xml"},
  body: %{
    "root" => %{
      "name" => "note",
      "attributes" => %{"id" => "1"},
      "children" => [%{"name" => "to", "children" => [%{"content" => "Ann"}]}]
    }
  }
)
```

- An XML description has a `"root"` element. An element is
  `%{"name", "attributes", "children"}`. A child is an element, a text node
  `%{"content" => "text"}` or a matcher element.
- A form description is a map of strings, numbers, matchers and lists of them.
  Nested maps, booleans, `nil` and keys that start with `"pact:"` return an error.
- A bad description returns `{:error, %PactEx.Error{code: -101}}` that names the
  interaction and the path of the problem.
- For raw XML or a raw form, pass a **string** plus `content_type:`. But a string
  that starts like JSON (`{"a`, `[`, `"`, `true`, `null`, digits: `1=a&2=b` and
  `null_flag=1` count) is read as a JSON description and returns an error if it
  is not a valid one. Do not start a raw form body with a digit or a keyword.
