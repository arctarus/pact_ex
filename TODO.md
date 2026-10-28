# TODO

Open issues from the plan 1 and plan 2 reviews. Done items are removed. The history is in git and in the SDD ledger, which is git-ignored.

## Plans

- [ ] Re-review plan 3 against the plan 1 code.

## Minor: code

- [ ] `pact_handle_write_file` code 2 says "is the directory writable?", but pact_ffi also returns 2 when it cannot merge with an existing pact file (`messages.rs:89`). Drop the hint or name both causes.
- [ ] README `on_exit` advice: a second `MockServer.stop/1` stops by port, so if the port was reused it can stop another test's server. Say to use `on_exit` instead of stopping in the test body, or make `stop/1` check the pact handle.
- [ ] Replace `<release date>` in `CHANGELOG.md` before tagging `v0.2.0`.
- [ ] Consider an upstream issue for pact-reference: pact_models `calc_content_type` (`v4/mod.rs:68`) indexes `v[0]` of a Content-Type header without a bounds check, so an empty header aborts the process.
- [ ] Each `mock_server_mismatches` call leaks a CString into pact_ffi until cleanup. Document it, or avoid polling.
- [ ] A huge `examples` count in an XML description can stall `with_body` or run out of memory. It isn't rejected, because pact_ffi accepts it.
- [ ] pact_ffi silently drops a form value whose matcher fails to build (e.g. `regex` without `"regex"`).
- [ ] Rust cleanups:
  - the `Created` wrapper is redundant, since the `Result` encoder already does its job;
  - the `Outcome` encoder has an unneeded `clone`.
- [ ] `String.trim/1` and Rust's `str::trim` may disagree on some Unicode whitespace (log file paths).
- [ ] Replace `unless` in `PactEx.Matchers` (soft-deprecated style).
- [ ] The pact_models matcher-expression parser (`matching(...)` strings) has not been audited for panics.
- [ ] Header maps whose keys collapse to the same name after dashing (e.g. `%{:x_request_id => "1", "x-request-id" => "2"}`) silently overwrite one value; reject like two Content-Type spellings.
- [ ] `apply.ex` module summary (lines ~9 and ~30-34): mention atom header-name dashing and that an element resolving to `[]` at any position is rejected.

## Minor: tests

- [ ] Response-side Content-Type e2e assertion is weak (pact_ffi adds Content-Type from the text body anyway): add a key-set assertion; add a test for `%{content_type: "a", "Content-Type" => "b"}` → error; fix the `apply_test` comment ("no FFI builder call", not "no native call").
- [ ] `large_body_test.exs`: restore microstate accounting in `on_exit`; the `dirty > 0` assertion could false-pass on an unrelated dirty GC.
- [ ] No test for the non-UTF-8 candidate branch in `Apply.classify/1`.
- [ ] No collision test for a query matcher map.
- [ ] `with_body` and `with_binary_body` are only tested natively with `:response`.
- [ ] Some response-side matching-rule assertions are loose, and `$.attributes` is pinned by pattern instead of equality.
- [ ] Weak `ArgumentError` message assertions in the builder tests. Loop tests don't name the failing value.
- [ ] The Rust logger test leaks pact handles and duplicates `fail_given_with_params`.
- [ ] The stack test aborts the test binary on regression instead of failing cleanly. `RUST_MIN_STACK` ≥ 4 MiB would hide a regression.
- [ ] Test-support modules (`PactFile`, `AnimalClient`) are in the global namespace. `consumer_test.exs` keeps its own `read_pact`.
- [ ] Abort matrix: add an `:ok` case for a working mixed Content-Type list such as `[%{"value" => ["a"]}, "text/plain"]` (only unit-tested today).
- [ ] `System.put_env("PACT_PLUGIN_DIR", ...)` in `native/plugins_test.exs` and in the `plugin_contents_test.exs` `load_all` tests never reaches the plugin driver, so those tests do not exercise the missing-dir path they describe. Locally, `mix test` still reaches GitHub for the missing-plugin tests unless `HTTPS_PROXY` is set in the shell.
- [ ] Remove the duplicate out-of-range create test, and the stray path comment on line 1 of `test/pact_ex/native/mock_server_test.exs`.
