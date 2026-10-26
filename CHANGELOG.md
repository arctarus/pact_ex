# Changelog

## Unreleased

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
