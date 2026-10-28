# Changelog

## 0.2.0 - <release date>

- Async messages: `PactEx.Message` and `PactEx.Message.Reified`.
  `Message.run/4` and `run!/4` build the message, call your function with the
  reified contents and write the pact in merge mode. Messages need a V4 pact.
- Sync messages: `PactEx.SyncMessage` and `PactEx.SyncMessage.Generated`, with
  one request and any number of responses, each with its own content type.
- Pact plugins: `PactEx.using_plugin/3`, `PactEx.Plugin` and
  `PactEx.PluginContents`. `PactEx.Plugin.contents/2` is a request, response or
  message body that a plugin builds. It works with HTTP interactions and with
  both kinds of message. The plugins of a pact are loaded when a run starts and
  always unloaded when it ends, also when your function raises.
- gRPC transport: `SyncMessage.run/4` with `transport: "grpc"` starts the
  mock server that the protobuf plugin provides, and checks it as
  `Consumer.run/4` does.
- A message or response body that a plugin builds as binary (protobuf) reaches
  your function as raw bytes.
- `scripts/install-protobuf-plugin.sh` installs the protobuf plugin 0.8.1 for
  CI and for a checkout of this repository. The tests that need a plugin are
  skipped when it is not installed.
- `PactEx.Consumer.run/4` returns `{:error, %PactEx.Error{code: -102}}` when
  the mock server reports a failed match without mismatch details, for
  example when it was already stopped. It used to return an empty
  `PactEx.MismatchError`.
- `PactEx.MismatchError` messages include the `error` field that plugin mock
  servers report.
- The NIFs that build pacts and interactions run on dirty IO schedulers, so a
  large body or a wait on pact_ffi's global lock no longer blocks a normal
  scheduler. Pacts are freed on a background thread.

## 0.1.0 - 2026-10-23

First release.

- HTTP consumer tests: `PactEx.new/3`, `PactEx.HTTP`, `PactEx.Consumer.run/4`
  and `run!/4`, `PactEx.Consumer.start_mock_server/3` and `PactEx.MockServer`.
- Matchers in `PactEx.Matchers`.
- Native log setup with `PactEx.Log.init/1`.
- Precompiled NIFs for `aarch64`/`x86_64` on macOS, Linux (glibc) and Linux
  (musl), for NIF versions 2.16 and 2.17.
