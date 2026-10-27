# TODO

Open issues from the plan 1 and plan 2 reviews. Done items are removed. The history is in git and in the SDD ledger, which is git-ignored.

## Plans

- [ ] Re-review plan 3 against the plan 1 code.

## Plan 2: third review

Plan 2 was written before PR #4 added Credo (strict), Dialyzer and `mix precommit`. These fixes make it pass those checks.

- [ ] Run the checks in every task. Add a Global Constraint: the code passes `mix precommit`. That covers compile with warnings as errors, format, Credo strict (Specs, StrictModuleLayout, ModuleDoc) and Dialyzer. End each task's "verify they pass" step with `mix precommit`. A task that touches `native/` also runs `cargo fmt --check`, `cargo clippy --all-targets -- -D warnings` and `cargo test`. Task 7 Step 4 uses the same commands. Its clippy call lacks `--all-targets`, which CI uses.
- [ ] Credo AliasUsage in the test snippets. `plugin_test.exs` (Task 2) calls `PactEx.Consumer.Apply.validate/1`, and the gRPC test (Task 5) calls `Routeguide.RouteGuide.Stub.get_feature/2`. Alias both.
- [ ] Task 5 polls `pgrep` twice, with a `;` (Credo Semicolons). Move the poll to one helper in `test/support`, with `@moduledoc` and `@spec`, and use it in both tests.
- [ ] Task 5 Step 2: the four `Routeguide.*` modules in `test/support/route_guide.ex` need `@moduledoc`. Credo checks `.ex` files under `test/`.
- [ ] Task 5 Step 2: nobody has run `--warnings-as-errors` or Dialyzer on the code that `use Protobuf` and `use GRPC.Stub` generate. Add a check right after writing `route_guide.ex`: `MIX_ENV=test mix compile --warnings-as-errors` and `mix dialyzer`. Say what to do if they warn.
- [ ] Task 4 specs `SyncMessage.run/4` with `PactEx.MismatchError.t()`, which it cannot return until Task 5. Dialyzer's `:extra_return` may flag it. Spec it without `MismatchError` in Task 4 and widen the spec in Task 5.
- [ ] The "Status: Written before plan 1 was implemented" header is stale. Plan 2 was reviewed three times against the plan 1 code.
- [ ] Task 7 Step 3 adds a `0.2.0` section to `CHANGELOG.md`, but an `## Unreleased` section already exists. Turn it into `0.2.0` and add the plan 2 entries.

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
