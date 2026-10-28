# PactEx

[Pact](https://pact.io) contract testing for Elixir. PactEx is a
[Rustler](https://github.com/rusterlium/rustler) NIF over the `pact_ffi` library,
distributed with [`rustler_precompiled`](https://hex.pm/packages/rustler_precompiled),
so you do not need Rust to use it.

This release covers consumer tests: HTTP, asynchronous and synchronous
messages, Pact plugins (for example protobuf) and a gRPC mock transport. The
provider verifier is not here yet. See [Coming next](#coming-next).

## Installation

Add `pact_ex` to your test dependencies:

```elixir
def deps do
  [
    {:pact_ex, "~> 0.2.0", only: :test}
  ]
end
```

`mix deps.get` and `mix compile` download the precompiled NIF for your platform
from the GitHub release. Rust is only needed to
[build from source](#building-from-source).

Requires Elixir 1.18 or later.

## Quick start

```elixir
import PactEx.Matchers

pact = PactEx.new("my_app", "user_service", pact_dir: "pacts")

interaction =
  PactEx.HTTP.interaction("get user by id")
  |> PactEx.HTTP.given("user exists", %{"id" => "123"})
  |> PactEx.HTTP.with_request(:get, "/users/123", headers: %{"accept" => "application/json"})
  |> PactEx.HTTP.will_respond_with(200, body: %{"id" => like(123), "name" => like("John")})

:ok =
  PactEx.Consumer.run(pact, [interaction], fn mock ->
    # Point your HTTP client at the mock server.
    {:ok, _user} = UserClient.get(mock.url, "123")
  end)
```

`PactEx.new/3` builds a plain struct. The spec defaults to `:v4` and `pact_dir`
to `"pacts"`. `PactEx.HTTP` builds interactions as plain data, so nothing
touches the native library until `run/4`.

### What `PactEx.Consumer.run/4` does

It starts a mock server on `127.0.0.1` with an OS-assigned port, calls your
function with the `PactEx.MockServer` (use `mock.url`), and then:

- **Everything matched.** It writes `<pact_dir>/<consumer>-<provider>.json` in
  merge mode and returns `:ok`. If the file exists, the new interactions are
  merged into it, so several tests can contribute to one pact.
- **Something did not match.** An expected request never arrived, or an
  unexpected one did. It returns `{:error, %PactEx.MismatchError{}}` and writes
  nothing. `:mismatches` holds the decoded mismatch maps.
- **Your function raises, throws or exits.** The mock server is stopped, nothing
  is written, and the exception propagates.
- **The server could not start or the pact could not be written.** It returns
  `{:error, %PactEx.Error{}}`.
- **The server reported a failed match without mismatch details.** For example
  a plugin mock server that failed to answer, or a server your function already
  stopped. It returns `{:error, %PactEx.Error{code: -102}}` and writes nothing.

The mock server is stopped when your function returns, raises, throws or exits.
A brutal kill of the calling process (an ExUnit timeout or a linked crash)
skips the cleanup, and the server lives until the OS process exits. `run!/4`
returns `:ok` or raises the error. Options are `:host` and `:port`.

For more control, use `PactEx.Consumer.start_mock_server/3`, then
`PactEx.MockServer.matched?/1`, `mismatches/1`, `write_pact/2` and `stop/1`.

### Bodies, query parameters and headers

**Body encoding.** This applies to request and response bodies.

Each request and response has one content type. The candidates are the
`content_type:` option, then the `Content-Type` header, then the default of the
body type. Each is trimmed, and PactEx uses the first one that pact_ffi can
parse (`"application/json; charset"` and `"application/json,"` cannot be
parsed, so they are skipped). That one string is what pact_ffi gets with the
body. When it came from a string header, the header is written with it too.
This holds for every body type.

| You pass | Default content type | Sent as |
|---|---|---|
| A map or list | `application/json` | JSON. |
| A UTF-8 string | `text/plain` | Text, byte for byte (see XML and form bodies below). |
| A binary that is not valid UTF-8, or has NUL bytes | `application/octet-stream` | A binary body. |

Any other body type returns `{:error, %PactEx.Error{}}`.

The `Content-Type` header name can be in any case. It is written as
`Content-Type`, so the pact has one entry. Two headers that differ only in case
return an error. The value can be a string, a matcher (its `"value"` is used)
or a list (its first element is used). The header is sent as you wrote it, even
when `content_type:` differs. A value that pact_ffi would turn into an empty
list returns an error: a map or a JSON string with `"value" => []` (a matcher
too), alone or as any element of a list. As the whole header, or as the last
element, it makes pact_ffi abort the VM. Before a later element, pact_ffi
records an empty string (`["", "text/plain"]`). An empty or whitespace-only
string, as the value or as any element (also as a matcher's `"value"`, alone or
in its array), returns an error too: pact_ffi records it as an empty content
type. The reason depends on the side. On a request, no client sends such a
header, so no request of the interaction can match it. On a response, the mock
server would serve a meaningless header that no provider can produce. The check
ignores the body and `content_type:`. (An empty `content_type:` is not an
error: it is skipped, like any value pact_ffi cannot parse.)

**XML and form bodies.** With an XML content type (`application/xml`,
`text/xml`, or `application/` or `text/` with a `+xml` suffix) or
`application/x-www-form-urlencoded`, pact_ffi does not send a JSON body as it
is. It reads it as a description of the body in its own format. This applies to
a map or list, and also to a string that pact_ffi's content sniffing takes for
JSON (see below). PactEx checks the description before it calls pact_ffi,
because some shapes make pact_ffi panic, which would abort the VM. A bad
description returns `{:error, %PactEx.Error{code: -101}}` that names the
interaction and the path of the problem. A type that is both JSON and XML
(`application/xml+json`) is JSON.

pact_ffi sniffs a string by its first characters only, not by parsing it.
After optional leading whitespace (Unicode whitespace counts; a BOM does not),
the text must start with one of these:

- `true`, `false` or `null`, or one or more ASCII digits (`-1` does not
  count);
- a `"` (anything may follow);
- `{` and optional whitespace, then `}` or a `"` and a word character (`{ }`,
  `{"a`). `{"":1}` and `{"-a":1}` are not sniffed, because the first key is
  empty or starts with a non-word character;
- `[` and optional whitespace. Anything may follow.

A word character is a Unicode word character (letters, marks, digits,
connector punctuation such as `_`). Nothing after that prefix is looked at, so
`1=a&2=b`, `null_flag=1` and `123 items` are sniffed as JSON.

A string that is not sniffed as JSON (raw XML, `a=1&b=2`) is sent byte for byte.
A string that is sniffed as JSON must be a JSON object that is a valid
description. For XML, a description is turned into XML. A raw form string that
is sniffed as JSON, such as `1=a&2=b` or `null_flag=1`, returns an error,
because pact_ffi would panic on it.

An XML description is a map with a `"root"` element. An element is
`%{"name" => ..., "attributes" => %{...}, "children" => [...]}`. A child is an
element, a text node `%{"content" => "text"}`, or a matcher element
`%{"pact:matcher:type" => "type", "value" => element}`. Any child can have an
`"examples"` count that is an integer from 0 up. A form description is a map of
strings, numbers, matchers with such a value, and lists of them. pact_ffi drops
nested maps, booleans, `nil` and keys that start with `"pact:"` from a form body,
so they return an error.

PactEx encodes every JSON once and checks those exact bytes. An object that
repeats a key returns an error, at any depth, for every content type. This
covers keys that collide once turned into strings (`%{a: 1, "a" => 2}`), structs
that encode to a repeated key, and matcher maps in headers, paths and provider
state params. JSON readers disagree on which key wins.

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

For raw XML or a raw form, pass a string:

```elixir
PactEx.HTTP.with_request(interaction, :post, "/notes",
  body: "<note>hi</note>",
  content_type: "application/xml"
)
```

**Query parameters and headers.** Names are strings or atoms. Values are
strings, numbers, booleans, matchers or lists. Numbers and booleans become
strings. A list gives a multi-valued parameter:

```elixir
PactEx.HTTP.with_request(interaction, :get, "/animals",
  query: %{"tag" => ["a", "b"], limit: 10, active: true},
  headers: %{"x-request-id" => regex("abc-1", "[a-z]+-\\d+")}
)
```

`query:` and `headers:` also take a keyword list or a list of `{name, value}`
tuples, as Req and Plug do. Anything else (a string, a list that holds
something other than a `{name, value}` tuple) raises `ArgumentError`. A name
that repeats gets all its values, in order:

```elixir
PactEx.HTTP.with_request(interaction, :get, "/animals",
  query: [tag: "a", tag: "b", limit: 10],
  headers: [{"x-request-id", "abc-1"}, accept: "application/json"]
)
```

That is `%{"tag" => ["a", "b"], "limit" => 10}` for the query. A list value
counts as several values (`[tag: ["a", "b"], tag: "c"]` has three). Query names
are case-sensitive. Header names are not, so `[{"Accept", "a"}, accept: "b"]`
is one header with two values, named as in its first spelling. A map is never
merged and is used as you wrote it.

An atom header name is written as Req writes it, in a map and in a list:
underscores become dashes and ASCII letters lower case, so `x_request_id: "1"`
is the header `x-request-id` and `content_type: "text/plain"` is
`Content-Type`. A string name is used as it is (`"x_id"` stays `"x_id"`). Query
names are not changed (`page_size: 2` is `page_size`).

`nil` and other types return `{:error, %PactEx.Error{}}`. So does an empty list
(`"tag" => []`), which would drop the parameter without a word. The error names
the header or parameter.

## Matchers

`import PactEx.Matchers` and put the result where you would put a plain value:
in a body, a header, a query value or a path. The mock server matches by rule,
and the example value is what it returns to your code.

| Function | Matches | Notes |
|---|---|---|
| `like(value)` | Any value of the same type | |
| `each_like(value, min: n)` | A list whose elements look like `value` | At least `n` elements, default `1`. The example list repeats `value` `n` times. |
| `regex(value, pattern)` | A string matching `pattern` | `value` is the example. |
| `each_key(map, pattern)` | A map whose keys match `pattern` | |
| `integer(value)` | Any integer | |
| `decimal(value)` | Any decimal number | `value` must be a float. An integer raises `FunctionClauseError`, so write `2.0`. |
| `boolean(value)` | `true` or `false` | |
| `datetime(value, format)` | A date or time string in a Java `DateTimeFormatter` format | e.g. `"yyyy-MM-dd"`. |
| `include(substring)` | A string containing `substring` | |

Matchers nest:

```elixir
%{
  "id" => integer(1),
  "name" => like("Ada"),
  "email" => regex("ada@example.com", ".+@.+"),
  "tags" => each_like(like("admin"), min: 2)
}
```

## Async messages

An asynchronous message is an event, such as a message on a queue. The consumer
test builds the message, gets it as a provider would send it, and passes it to
the code that handles it.

```elixir
import PactEx.Matchers
alias PactEx.Message

pact = PactEx.new("animal_service", "weather_service", pact_dir: "pacts")

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
    # contents == %{"temperature" => 23.0, "timestamp" => "2024-03-14T10:22:13+05:30"}
    # metadata["queue"] == "weather.eu"
    WeatherConsumer.handle(contents, metadata)
  end)
```

`Message.run/4` replaces matchers with their example values, and calls your
function with a `PactEx.Message.Reified`. If the function returns, it writes
`<pact_dir>/<consumer>-<provider>.json` in merge mode, so several runs can add
messages to one pact. If it raises, throws or exits, nothing is written and the
exception propagates. `run!/4` returns `:ok` or raises the error.

- Messages need a V4 pact, which is the default. Any other spec returns
  `{:error, %PactEx.Error{}}`.
- A message needs contents. Contents are a map or list (JSON, matchers are
  allowed), a binary, or [plugin contents](#plugins).
- Metadata values are sent as JSON, so the string `"5"` stays a string. A value
  can be a matcher.
- For a JSON content type, `contents` is the decoded JSON. For any other type
  it is the raw bytes, for example a protobuf message.

## Sync messages

A synchronous message has one request and one or more responses, such as a gRPC
call.

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

`SyncMessage.run/4` works like `Message.run/4`. Your function gets a
`PactEx.SyncMessage.Generated` with `:request` and `:responses`. Each response
has its own content type: `will_respond_with(message, contents, content_type:
"text/plain")` sets it for that response only.

With the `:transport` option, `run/4` also starts the mock server of a plugin
transport. See [the gRPC example](#grpc).

## Plugins

A [Pact plugin](https://github.com/pact-foundation/pact-plugins) teaches Pact a
content type or a transport, for example protobuf and gRPC. Declare the plugins
of a pact with `PactEx.using_plugin/3`:

```elixir
pact =
  "web"
  |> PactEx.new("user_service")
  |> PactEx.using_plugin("protobuf", "0.8.1")
```

The plugins are loaded when a mock server or a message test starts, and
unloaded when it stops. A pact can use each plugin name once.

### Installing a plugin

In a checkout of this repository, run `scripts/install-protobuf-plugin.sh`. It
installs the protobuf plugin 0.8.1 in `$PACT_PLUGIN_DIR/protobuf-0.8.1`, or in
`~/.pact/plugins/protobuf-0.8.1` when `PACT_PLUGIN_DIR` is not set. It checks
every download against a SHA-256.

The Hex package does not include `scripts/`. If you use PactEx from Hex, install
a plugin with `pact-plugin-cli install`, or with the `install-plugin.sh` that
the plugin's release ships. Or rely on auto-install, below.

`PactEx.Plugin.installed?/2` tells whether a plugin is in the plugin directory.

### Auto-install

A plugin that is not installed is downloaded from the pact-plugins index on
GitHub when the test runs. So that run needs network access.

- Offline, a missing plugin returns an error that starts with the plugin name
  and version. The rest is `Could not load plugin - ` and the driver's message:
  `Plugin ... was not found`, or `Plugin directory "..." does not exist` when
  there is no plugin directory at all.
- The download has no timeout. On a network that drops packets, a test that
  loads a plugin can hang, and the driver holds its plugin lock meanwhile. That
  hung download also blocks every plugin cleanup. pact_ffi guards all pact
  builders with one global lock, and a cleanup holds it while it waits for the
  plugin lock. So every pact builder call in the VM waits too, and other tests
  stall with it.
- Each plugin load takes at least 500 ms.

### Using a plugin

`PactEx.Plugin.contents/2` describes a body that a plugin builds. Pass the
content type that picks the plugin, and the description the plugin reads. Use
the result as the `:body` of an HTTP request or response, as the contents of an
async message, or with `SyncMessage.with_plugin_contents/2`:

```elixir
alias PactEx.{HTTP, Plugin}

body =
  Plugin.contents("application/protobuf", %{
    "pact:proto" => Path.expand("route_guide.proto"),
    "pact:message-type" => "Feature",
    "pact:content-type" => "application/protobuf",
    "name" => "notEmpty('Big Tree')"
  })

interaction =
  HTTP.interaction("get feature")
  |> HTTP.with_request(:get, "/feature")
  |> HTTP.will_respond_with(200, body: body)
```

A body that a plugin builds is not a plain map. The plugin returns the body and
its matching rules. Using plugin contents in a pact that does not declare the
plugin returns `{:error, %PactEx.Error{code: -101}}`.

A plugin message arrives as raw bytes: decode it with your protobuf module, for
example `Routeguide.Feature.decode(bytes)`.

### gRPC

A synchronous message with plugin contents and `transport: "grpc"` starts the
gRPC mock server of the protobuf plugin. Your function gets its port in
`generated.transport.port`, and its address (`"127.0.0.1:50051"`, not a URL) in
`generated.transport.address`.

```elixir
pact =
  "grpcconsumer"
  |> PactEx.new("grpcprovider")
  |> PactEx.using_plugin("protobuf", "0.8.1")

message =
  SyncMessage.new("Route guide - GetFeature")
  |> SyncMessage.given("feature 'Big Tree' exists")
  |> SyncMessage.with_plugin_contents(
    Plugin.contents("application/protobuf", %{
      "pact:proto" => Path.expand("route_guide.proto"),
      "pact:proto-service" => "RouteGuide/GetFeature",
      "pact:content-type" => "application/protobuf",
      "request" => %{
        "latitude" => "matching(number, 180)",
        "longitude" => "matching(number, 200)"
      },
      "response" => %{
        "name" => "notEmpty('Big Tree')",
        "location" => %{
          "latitude" => "matching(number, 180)",
          "longitude" => "matching(number, 200)"
        }
      }
    })
  )

:ok =
  SyncMessage.run(
    pact,
    message,
    fn %{transport: %{address: address}} ->
      # Use your own gRPC client, here the grpc hex package.
      {:ok, channel} = GRPC.Stub.connect(address)
      point = %Routeguide.Point{latitude: 180, longitude: 200}

      try do
        {:ok, %Routeguide.Feature{name: "Big Tree"}} =
          Routeguide.RouteGuide.Stub.get_feature(channel, point)
      after
        GRPC.Stub.disconnect(channel)
      end
    end,
    transport: "grpc"
  )
```

Like `Consumer.run/4`, a run with a transport checks the mock server after your
function returns. It writes the pact only if every expected request arrived and
matched. Otherwise it returns `{:error, %PactEx.MismatchError{}}`. The other
options are `:host`, `:port` and `:transport_config`. When the plugin mock
server reports a failed match without any details, the run returns
`{:error, %PactEx.Error{code: -102}}`, and nothing is written. To answer with a
gRPC error, set `"responseMetadata" => %{"grpc-status" => "NOT_FOUND"}` in the
description. The client then gets a gRPC error, not a decoding failure. The
full test is
[`test/acceptance/grpc_consumer_test.exs`](https://github.com/arctarus/pact_ex/blob/main/test/acceptance/grpc_consumer_test.exs).

### The cleanup guarantee

Plugins are OS processes, and they outlive a test that forgets them. So every
run that loads plugins unloads them again, on the same pact:

- `Message.run/4`, `SyncMessage.run/4` and `Consumer.run/4` unload them when
  your function returns, raises, throws or exits. A load that fails also
  unloads the plugins that were loaded before it.
- `Consumer.start_mock_server/3` unloads them when you call
  `PactEx.MockServer.stop/1`, or when it returns an error.
- Unloading happens once per pact, so a second call, such as `stop/1` after a
  `run/4`, does nothing. A plugin process exits when no pact uses it any more,
  so two pacts can share one process.

The unloading and the freeing of the pact can finish a moment later, so a plugin
process can still be there for a short time after `run/4` returns. A brutal kill
of the calling process (an ExUnit timeout or a linked crash) skips the explicit
cleanup. The pact is then cleaned up when the VM garbage collects it, on a
background thread, which can take longer.

Garbage collection is not a fallback when the VM exits. A mock server that is
still referenced at that point leaves its plugin process running. When you use
`start_mock_server/3` in a test, stop the server in `on_exit`, right after you
start it:

```elixir
{:ok, mock} = PactEx.Consumer.start_mock_server(pact, interactions)
on_exit(fn -> PactEx.MockServer.stop(mock) end)
```

## Logging

The native library keeps one logger for the whole OS process. Set it up once,
early, for example in `test/test_helper.exs`:

```elixir
PactEx.Log.init(level: :debug, sink: {:file, "tmp/pact.log"})
```

- `:level` is `:off`, `:error`, `:warn`, `:info` (default), `:debug` or `:trace`.
- `:sink` is `:stdout` (default), `:stderr` or `{:file, path}`. A file sink
  appends, and creates missing parent directories. The path must not be blank
  or have leading or trailing whitespace. Prefer a file, because `:stdout` and
  `:stderr` mix Pact output with your test output.

`init/1` succeeds once per OS process. Later calls return
`{:error, :already_initialized}`. A sink that cannot be set up returns
`{:error, %PactEx.Error{}}`. Logs are not forwarded to Elixir's `Logger`.

## Building from source

Precompiled NIFs are the default. To compile the NIF yourself you need Rust 1.91
or later and a C compiler:

```sh
PACT_EX_BUILD=1 mix deps.compile pact_ex --force
```

`PACT_EX_BUILD` is read at compile time. If you change it, recompile the
dependency with `mix deps.compile pact_ex --force`. Setting it when you run
`mix test` is not enough once `pact_ex` is already compiled.

The first build compiles `pact_ffi` and takes a few minutes. `rustler` is an
optional dependency of `pact_ex`, so add it to your own `deps` when you build
from source:

```elixir
{:rustler, "~> 0.38", only: :test, runtime: false}
```

In this repository, `config/config.exs` forces the build in `dev` and `test`, so
`mix test` builds the NIF:

```sh
mix deps.get
mix test
```

CI also runs Credo and Dialyzer. `mix precommit` runs the Elixir checks of CI
in one go: compile with warnings as errors, the formatter check, Credo,
Dialyzer and the tests. To run it before every push, enable the hook in
`.githooks` once per clone:

```sh
git config core.hooksPath .githooks
```

`git push --no-verify` skips it for one push.

## Supported platforms

Precompiled NIFs exist for NIF versions 2.16 (OTP 25) and 2.17 (OTP 26, 27 and
28) on:

| OS | Architectures |
|---|---|
| macOS | `aarch64`, `x86_64` |
| Linux (glibc) | `aarch64`, `x86_64` |
| Linux (musl, for example Alpine) | `aarch64`, `x86_64` |

The glibc builds need, as measured on the release artifacts:

- `x86_64-unknown-linux-gnu`: glibc 2.34 or later (built on Ubuntu 22.04). That
  excludes Debian 11, Ubuntu 20.04, RHEL 8 and Amazon Linux 2.
- `aarch64-unknown-linux-gnu`: glibc 2.18 or later (built in a `cross` image).

On older systems `rustler_precompiled` still picks the glibc target, so the
precompiled NIF cannot load. Build from source there (`PACT_EX_BUILD=1`, see
[building from source](#building-from-source)). The musl builds are for
musl-based systems such as Alpine, not a fallback for old glibc.

There is no Windows build. CI runs the tests on Linux and macOS with OTP 26,
27 and 28.

## Coming from pact_erlang

| pact_erlang | PactEx | Status |
|---|---|---|
| `pact:v4/2` | `PactEx.new/3` | Available |
| `pact:interaction/2` (given, with or without params; request method, path, headers, query, body; response status, headers, body) | `PactEx.HTTP.*` and `PactEx.Consumer.start_mock_server/3` | Available |
| `pact:verify/1` | `PactEx.MockServer.matched?/1`, `mismatches/1` | Available |
| `pact:write/1,2` | `PactEx.MockServer.write_pact/2` | Available |
| `pact:cleanup/1` | `PactEx.MockServer.stop/1` | Available |
| `pact:like/1`, `each_like/1`, `regex_match/2`, `each_key/2` | `PactEx.Matchers` | Available |
| `pact:enable_logging/1,2` | `PactEx.Log.init/1` | Available |
| `pact:msg_interaction/2` (async messages) | `PactEx.Message` | Available |
| Plugins, sync messages, gRPC transport (new) | `PactEx.using_plugin/3`, `PactEx.Plugin`, `PactEx.SyncMessage` | Available |
| `pact_verifier:start_verifier/2`, `verify/1` (file and broker sources, message providers, state change URL, publish results) | `PactEx.Verifier` | Plan 3 |
| Provider transports such as `grpc` (new) | `PactEx.Verifier` | Plan 3 |

## Coming next

The provider verifier (plan 3), with file, directory and broker sources, state
change URL, message providers, result publishing and provider transports.

## License

MIT. See `LICENSE`.
