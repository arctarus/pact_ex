# TODO

Open issues from the plan 1 reviews and the plan 2 review. The full history is in the SDD ledger, which is git-ignored.

## Before plan 2

Found when plan 2 (`docs/superpowers/plans/2026-10-22-pact-ex-2-messages-plugins.md`) was reviewed against the plan 1 code, pact_ffi 0.5.12 and pact-plugin-driver 1.2.6. Do not start plan 2 until every blocking item is done. Items marked "plan" are changes to the plan text. Items marked "code" are changes to the plan 1 code.

### Blocking

- [x] **code** Clean up the plugins of a pact handle exactly once. `pactffi_cleanup_plugins` decrements a global per-plugin access count on every call and does not check whether the handle was already cleaned. The plan calls it from `MockServer.stop/1` (documented as idempotent), from the `start_mock_server` failure path, and from nested `after` blocks. A second call can kill a plugin process that a concurrent pact still uses. `PactResource::drop` doesn't clean up at all, so a pact that is never cleaned up leaks the process. Fix: add an `AtomicBool` to `PactResource`, have the `cleanup_plugins` NIF compare-and-swap it, and clean up in `Drop` too.
- [ ] **plan** Deduplicate plugins in `PactEx.using_plugin/3`, or reject a repeated name. Each `pactffi_using_plugin` call increments the count, but cleanup decrements once per unique plugin (`plugin_data()` is `unique`). A repeated plugin leaks its process.
- [x] **code** Wrap `mock_server_matched` and `mock_server_mismatches` in `on_large_stack`. For a plugin mock server they run a gRPC `block_on` while holding `MANAGER`.
- [ ] **code + plan** Handle plugin mismatches:
  - They have the shape `path` / `error` / `mismatches`, without `type` or `method`. Teach `MismatchError.describe/1` that shape.
  - A failed plugin RPC makes `pactffi_mock_server_mismatches` return null, which today becomes `[]` and an empty `MismatchError` that looks like a real mismatch. Return a `PactEx.Error` instead.
- [ ] **plan + code** Body rules for plugin contents and messages:
  - `%PluginContents{}` is a map, so it hits the `is_map(body)` clause of `Apply.plan_part/3` (`apply.ex:108`) during `validate/1`. The new clause must come before that one in `plan_part`, not only in `interaction/2`.
  - The plan says to reuse the body rules, but `plan_part/3` is private and expects a struct with `headers`. Name the public function to extract (body plus explicit content type, without headers) before Task 3.
  - `invalid/1` hard-codes `"PactEx.Consumer.start_mock_server/3"`. Pass the entry point in, so message errors name `Message.run/4` or `SyncMessage.run/4`.
- [ ] **plan** JSON-encode every message metadata value, strings included. `pactffi_with_metadata` parses each value as JSON first and only falls back to a string if that fails, so passing a binary through turns `"5"`, `"true"` and `"null"` into a number, a boolean and null.
- [ ] **plan** Message spec and empty contents:
  - `pactffi_message_reify` returns the V3 shape (no `contents.content` envelope) for a pact with spec ≤ V3. Make `Message.run/4` require `:v4`.
  - Make `SyncMessage.run/4` reject a pact that isn't `:v4`, instead of silently overriding `pact.spec`.
  - A message without contents reifies to `""`, which gives a generic error with no stored message. Validate in Elixir that contents are present.
  - A `Null` body reifies to `"null"`, which has no envelope. Handle that case.
- [ ] **plan** Rewrite the message end-to-end test (Task 3). `@tag :tmp_dir` gives each test its own directory, and ExUnit randomizes test order, so a shared directory where the last test asserts 4 interactions can't work. Use one directory from `setup_all` with a single test, or assertions that don't depend on order.
- [ ] **plan** Plugin loading (decided: keep auto-install):
  - `Plugin.load_all/2` (or the NIF) puts the plugin name and version at the start of the error message. Without a plugin directory, the driver says `Plugin directory "..." does not exist` without naming the plugin, so the Task 1 assertion fails on a fresh machine.
  - Document that a missing plugin is installed from the pact-plugins index at test run time, which needs network access.
  - Without network the driver falls back to its built-in index, so a missing plugin fails with "not found". Accept that the GitHub fetch has no timeout and can hang on a network that drops packets. It holds `PLUGIN_REGISTER` meanwhile. Each `using_plugin` call also sleeps a fixed 500 ms.

### Important

- [x] **code** Move the builder NIFs and `PactResource::drop` off the normal schedulers (`DirtyIo`), or document the stall. They take the global `PACT_HANDLES` lock, and pact_ffi holds that lock across plugin round trips (`interaction_contents` inside `with_interaction`, `message_reify` inside `with_message`). Those round trips take seconds while the protobuf plugin compiles a `.proto`.
- [ ] **spike** Check that protobuf plugin 0.8.1 reports requests it never received in `get_mock_server_results`. The Task 5 test "a gRPC interaction never called returns MismatchError" depends on it.
- [ ] **spike** Check how to set up the grpc 1.0 client in tests: whether `GRPC.Client.Supervisor` must be started in `test_helper.exs`, and which adapter dependency it needs.
- [ ] **plan** Task 5, Step 2 expects an `ArgumentError`, but compilation fails first. Write the `Routeguide` modules before the first run. Move the Task 2 protobuf-over-HTTP test into Task 5 instead of using `@tag :skip`.

### Minor

- [ ] **plan** `scripts/install-protobuf-plugin.sh` doesn't verify the published `.sha256` files. Release v-0.8.1 also ships an official `install-plugin.sh`. `scripts/` is not in the Hex `files`, so the README can't send Hex users there.
- [ ] **plan** Drop the `transport` option of `PactEx.Consumer`, or justify it. `MockServer.build_url/2` always uses `http://`.
- [x] **code** Move `arg_cstring` (`handles.rs`) and `port_arg` (`mock_server.rs`) to `args.rs`. The new message NIFs need `arg_cstring`.
- [ ] **plan** Task 7: bump the version, then build the precompiled NIFs and their checksums for the new release.
- [ ] Re-review plan 3 against the plan 1 code.

## Minor: code

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
- [ ] Remove the duplicate out-of-range create test, and the stray path comment on line 1 of `test/pact_ex/native/mock_server_test.exs`.
