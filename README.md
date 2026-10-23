# PactEx

[Pact](https://pact.io) contract testing for Elixir. PactEx is a
[Rustler](https://github.com/rusterlium/rustler) NIF over the `pact_ffi` library,
distributed with [`rustler_precompiled`](https://hex.pm/packages/rustler_precompiled),
so you do not need Rust to use it.

This release covers HTTP consumer tests. Messages, plugins and the provider
verifier are not here yet. See [Coming in plans 2-3](#coming-in-plans-2-3).

## Installation

Add `pact_ex` to your test dependencies:

```elixir
def deps do
  [
    {:pact_ex, "~> 0.1.0", only: :test}
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
records an empty string (`["", "text/plain"]`) that no client can match. The
check ignores the body and `content_type:`.

**XML and form bodies.** With an XML content type (`application/xml`,
`text/xml`, or `application/` or `text/` with a `+xml` suffix) or
`application/x-www-form-urlencoded`, pact_ffi does not send a JSON body as it
is. It reads it as a description of the body in its own format. This applies to
a map or list, and also to a string that pact_ffi's content sniffing takes for
JSON (text that starts like JSON: `{`, `[`, a digit, `true`, `false`, `null`,
a quote). PactEx checks the description before it calls pact_ffi, because some
shapes make pact_ffi panic, which would abort the VM. A bad description returns
`{:error, %PactEx.Error{code: -101}}` that names the interaction and the path of
the problem. A type that is both JSON and XML (`application/xml+json`) is JSON.

A string that is not sniffed as JSON (raw XML, `a=1&b=2`) is sent byte for byte.
A string that is sniffed as JSON must be a JSON object that is a valid
description. For XML, a description is turned into XML. A raw form string that
starts like JSON, such as `1=a&2=b` or `null_flag=1`, returns an error, because
pact_ffi would panic on it.

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

`nil` and other types return `{:error, %PactEx.Error{}}`.

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
| `pact:msg_interaction/2` (async messages) | `PactEx.Message` | Plan 2 |
| Plugins, sync messages, gRPC transport (new) | `PactEx.Plugin`, `PactEx.SyncMessage` | Plan 2 |
| `pact_verifier:start_verifier/2`, `verify/1` (file and broker sources, message providers, state change URL, publish results) | `PactEx.Verifier` | Plan 3 |
| Provider transports such as `grpc` (new) | `PactEx.Verifier` | Plan 3 |

## Coming in plans 2-3

- **Plan 2:** asynchronous and synchronous messages, Pact plugins (for example
  protobuf) and a gRPC mock transport.
- **Plan 3:** the provider verifier, with file, directory and broker sources,
  state change URL, message providers, result publishing and provider
  transports.

## License

MIT. See `LICENSE`.
