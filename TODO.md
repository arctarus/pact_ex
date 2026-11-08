# TODO

Open issues from the plan 1 and plan 2 reviews. Done items are removed. The history is in git and in the SDD ledger, which is git-ignored.

## Important: from the plan 2 review, for 0.2.1

- [ ] `SyncMessage` drops the request and the responses without a word when `plugin_contents` is set (`lib/pact_ex/sync_message/runner.ex:187`: `check_response_types/2` checks their types and then they are discarded). Everywhere else a lost value is a `-101`. Make `with_plugin_contents/2` together with `with_request/3` or `will_respond_with/3` return `-101`, and drop the `content_type` check of the responses, which has no effect. Do it soon: it turns a silent no-op into an error.
- [ ] `scripts/install-protobuf-plugin.sh:64` checks the binary only against the `.sha256` of the same release. That protects against a corrupt download, not against changed release files, and the binary is what runs. Pin the binary hash for each OS and architecture (4 constants, from the digest GitHub reports for each asset), like `MANIFEST_SHA256`. Update them with every plugin version.
- [ ] `already_cleaned_up` (`native/pact_ex_nif/src/plugins.rs:33`) uses code 2, which pact_ffi means as "Failed to load the plugin" for `pactffi_using_plugin`. Anyone who filters on `code` cannot tell them apart. Use another code, or delete the `plugins_cleaned` guard and its tests: the public API cannot reach it, because `pact_ref` is internal.

## Minor: code

- [ ] Wrong comment in `native/pact_ex_nif/src/plugins.rs:64`: it says the driver starts the plugin "while pact_ffi holds its global `PACT_HANDLES`". In pact_ffi 0.5.12 (`plugins/mod.rs:84-94`) `load_plugin` runs in `RUNTIME.block_on` before `with_pact`, so that mutex is not held during the load (it is for `interaction_contents`). The lock that stays held is the plugin driver's `PLUGIN_REGISTER`, as the README and `ci.yml` say. Also note there that every `pactffi_using_plugin` sleeps 500 ms, so each plugin test pays that plus the process start.
- [ ] Rust cleanups. rustler 0.38 encodes `Result<T, E>` as `{:ok, t} | {:error, e}` when both implement `Encoder`, and `FfiError` does:
  - `Text` (`native/pact_ex_nif/src/messages.rs:21`) and `Created` (`native/pact_ex_nif/src/mock_server.rs:81`) are not needed. `message_reify`, `sync_message_generate_contents` and `create_mock_server` can return `Result<_, FfiError>`, and their `error.clone()` goes;
  - `Outcome` stays, because it must encode `:ok` alone, but its encoder has an unneeded `clone`.
- [ ] Plugins load before `with_specification` in `Consumer.build` (`consumer.ex:219`) and after it in both message runners. It makes no difference, but pick one order.
- [ ] `pact_handle_write_file` code 2 says "is the directory writable?", but pact_ffi also returns 2 when it cannot merge with an existing pact file (`messages.rs:89`). Drop the hint or name both causes.
- [ ] `MockServer.stop/1` stops by port, so a second call can stop another test's server if the port was reused. The README (around line 493) already says to stop in `on_exit`, but not to avoid also stopping in the test body. Say that, or make `stop/1` check the pact handle.
- [ ] Consider an upstream issue for pact-reference: pact_models `calc_content_type` (`v4/mod.rs:68`) indexes `v[0]` of a Content-Type header without a bounds check, so an empty header aborts the process.
- [ ] Each `mock_server_mismatches` call leaks a CString into pact_ffi until cleanup. Document it, or avoid polling.
- [ ] A huge `examples` count in an XML description can stall `with_body` or run out of memory. It isn't rejected, because pact_ffi accepts it.
- [ ] pact_ffi silently drops a form value whose matcher fails to build (e.g. `regex` without `"regex"`).
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
- [ ] Native tests cover `with_body` with `:request` only on message interactions (`messages_test.exs`), and `with_binary_body` only with `:response`. Add HTTP `:request` cases for both.
- [ ] Some response-side matching-rule assertions are loose, and `$.attributes` is pinned by pattern instead of equality.
- [ ] Weak `ArgumentError` message assertions in the builder tests. Loop tests don't name the failing value.
- [ ] The Rust logger test `failure_keeps_a_message_stored_by_pact_ffi` (`native/pact_ex_nif/src/logger.rs`) copies `fail_given_with_params` from `error.rs` and never frees its pact handle.
- [ ] The stack test aborts the test binary on regression instead of failing cleanly. `RUST_MIN_STACK` ≥ 4 MiB would hide a regression.
- [ ] Test-support modules (`PactFile`, `AnimalClient`, `PluginProcesses`, `CollidingRoot`) are in the global namespace. Plan 3 adds `AnimalInteractions`, `AnimalProvider`, `Broker`, `GrpcInteractions` and two gRPC servers there too. Decide before plan 3 starts: namespace them all (for example `PactEx.Test.*`), or drop this item. `consumer_test.exs` keeps its own `read_pact`.
- [ ] Abort matrix: add an `:ok` case for a working mixed Content-Type list such as `[%{"value" => ["a"]}, "text/plain"]` (only unit-tested today).
- [ ] Locally, `mix test` reaches GitHub for the missing-plugin test (`native/plugins_test.exs:34`) unless `HTTPS_PROXY` is set in the shell. CI sets it on the test step (`ci.yml:95`). Document it in the README contributing section, or set it from the test.
- [ ] `test/pact_ex/native/mock_server_test.exs`: port 70_000 is tested twice (the single test at line 200 and the loop at line 207). Drop the single test, and the stray path comment on line 1.
