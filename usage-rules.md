# PactEx usage rules

PactEx is Pact contract testing for Elixir. It wraps the `pact_ffi` Rust library
through a precompiled NIF. It writes consumer pacts and verifies providers.

Sub-rules, read the one that matches the task:

- `pact_ex:consumer`: HTTP consumer tests, bodies, query, headers.
- `pact_ex:messages`: async and sync message tests.
- `pact_ex:plugins`: protobuf, gRPC and other Pact plugins.
- `pact_ex:verifier`: verifying a provider.

## Rules

- Tests that use a plugin or `PactEx.Verifier` go in `async: false` modules:
  a verification stops every plugin process of the VM.
- Build a pact with `PactEx.new(consumer, provider, opts)`. It is a plain struct.
  The spec defaults to `:v4` and `:pact_dir` to `"pacts"`.
- Build interactions with `PactEx.HTTP`, `PactEx.Message` or `PactEx.SyncMessage`.
  They are plain data. Nothing touches the native library until a `run/4`.
- Use `run/4` (or `run!/4`) for tests. They start and stop the mock server for you.
  Do not hand-roll `start_mock_server/3` unless you need the control.
- Put matchers (`import PactEx.Matchers`) where a plain value goes: `like/1`,
  `each_like/2`, `regex/2`, `each_key/2`, `integer/1`, `decimal/1`, `boolean/1`,
  `datetime/2`, `include/1`. `decimal/1` needs a float: write `2.0`, not `2`.
- `run/4` returns `:ok`, `{:error, %PactEx.MismatchError{}}` or
  `{:error, %PactEx.Error{}}`. Match on `:ok` in tests. Nothing is written to the
  pact file unless everything matched.
- Do not edit generated pact files in `pacts/`. They are written in merge mode,
  so several tests can contribute to one file.
- Keys in a map must be unique once turned into strings. `%{a: 1, "a" => 2}` is
  an error, at any depth.

## Logging

The native logger is global to the OS process. Set it once, early, in
`test/test_helper.exs`, and prefer a file:

```elixir
PactEx.Log.init(level: :debug, sink: {:file, "tmp/pact.log"})
```

A second call returns `{:error, :already_initialized}`.

## Environment

- `PACT_DO_NOT_TRACK=true` turns off the anonymous usage metric that the
  verifier posts to Google Analytics. Set it on networks that drop packets: the
  request has no timeout.
- `PACT_EX_BUILD=1` builds the NIF from source (needs Rust). It is read at
  compile time: run `mix deps.compile pact_ex --force` after you change it.
- `PACT_PLUGIN_DIR` is where plugins are installed. The default is `~/.pact/plugins`.
