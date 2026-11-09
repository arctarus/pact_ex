# TODO

Open issues from the plan 1 and plan 2 reviews. Done items are removed. The history is in git and in the SDD ledger, which is git-ignored.

## Minor: code

- [ ] Consider an upstream issue for pact-reference: pact_models `calc_content_type` (`v4/mod.rs:68`) indexes `v[0]` of a Content-Type header without a bounds check, so an empty header aborts the process.
- [ ] The pact_models matcher-expression parser (`matching(...)` strings) has not been audited for panics.

## Minor: tests

- [ ] Response-side Content-Type e2e assertion is weak (pact_ffi adds Content-Type from the text body anyway): add a key-set assertion; add a test for `%{content_type: "a", "Content-Type" => "b"}` → error; fix the `apply_test` comment ("no FFI builder call", not "no native call").
- [ ] `large_body_test.exs`: restore microstate accounting in `on_exit`; the `dirty > 0` assertion could false-pass on an unrelated dirty GC.
- [ ] No test for the non-UTF-8 candidate branch in `Apply.classify/1`.
- [ ] No collision test for a query matcher map.
- [ ] Native tests cover `with_body` with `:request` only on message interactions (`messages_test.exs`), and `with_binary_body` only with `:response`. Add HTTP `:request` cases for both.
- [ ] Some response-side matching-rule assertions are loose, and `$.attributes` is pinned by pattern instead of equality.
- [ ] Weak `ArgumentError` message assertions in the builder tests. Loop tests don't name the failing value.
- [ ] The Rust logger test `failure_keeps_a_message_stored_by_pact_ffi` (`native/pact_ex_nif/src/logger.rs`) copies `fail_given_with_params` from `error.rs` and never frees its pact handle.
- [ ] The stack test aborts the test binary on regression instead of failing cleanly. `RUST_MIN_STACK` ≥ 4 MiB would hide a regression.
- [ ] Test-support modules (`PactFile`, `AnimalClient`, `PluginProcesses`, `CollidingRoot`) are in the global namespace. Plan 3 adds `AnimalInteractions`, `AnimalProvider`, `Broker`, `GrpcInteractions` and two gRPC servers there too. Decide before plan 3 starts: namespace them all (for example `PactEx.Test.*`), or drop this item. `consumer_test.exs` keeps its own `read_pact`.
- [ ] Abort matrix: add an `:ok` case for a working mixed Content-Type list such as `[%{"value" => ["a"]}, "text/plain"]` (only unit-tested today).
- [ ] Locally, `mix test` reaches GitHub for the missing-plugin test (`native/plugins_test.exs:34`) unless `HTTPS_PROXY` is set in the shell. CI sets it on the test step (`ci.yml:95`). Document it in the README contributing section, or set it from the test.
- [ ] `test/pact_ex/native/mock_server_test.exs`: port 70_000 is tested twice (the single test at line 200 and the loop at line 207). Drop the single test, and the stray path comment on line 1.
