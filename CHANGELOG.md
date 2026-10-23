# Changelog

## Unreleased

First release.

- HTTP consumer tests: `PactEx.new/3`, `PactEx.HTTP`, `PactEx.Consumer.run/4`
  and `run!/4`, `PactEx.Consumer.start_mock_server/3` and `PactEx.MockServer`.
- Matchers in `PactEx.Matchers`.
- Native log setup with `PactEx.Log.init/1`.
- Precompiled NIFs for `aarch64`/`x86_64` on macOS, Linux (glibc) and Linux
  (musl), for NIF versions 2.16 and 2.17.
