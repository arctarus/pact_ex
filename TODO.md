# TODO

Open issues from the plan 1 reviews. The full history is in the SDD ledger, which is git-ignored.

## Important

- [ ] **Check the release dry run.** Push the branch and open the PR, or start `release.yml` by hand. Check that all 12 build jobs pass (the aarch64-gnu and musl cross builds are untested) and that `publish` is skipped. Read the "Check the glibc floor" output of the two gnu targets. Then update the glibc 2.34 floor in README and RELEASING to the measured x86_64 value, and note the aarch64 value. Then close this item and the "Dry-run `release.yml`" item below.

## Minor: code

- [ ] Decide on a literal `""` element in a Content-Type list (e.g. `["", "text/plain"]`): it is accepted today but pact_ffi stores it like the rejected empty-element case.
- [ ] Content-Type empty-element wording: update the module summary in `apply.ex` (~30-32) to cover the any-position rule; the "no client can match" rationale only fits the request side (response side: a provider can't produce it) in `apply.ex`, the error message, README and `consumer.ex`; reword "has its value that resolves…" and pin that non-list branch in a test.
- [ ] Consider an upstream issue for pact-reference: pact_models `calc_content_type` (`v4/mod.rs:68`) indexes `v[0]` of a Content-Type header without a bounds check, so an empty header aborts the process.
- [ ] Wrap `mock_server_matched` / `mock_server_mismatches` in `on_large_stack`. Plan 2 needs this, because plugin mock servers run gRPC `block_on` under `MANAGER`.
- [ ] Each `mock_server_mismatches` call leaks a CString into pact_ffi until cleanup. Document it, or avoid polling.
- [ ] Builder NIFs and resource `Drop` take the global `PACT_HANDLES` lock on normal schedulers, so they can stall while a pact write runs. Document it, or make them `DirtyCpu`.
- [ ] A huge `examples` count in an XML description can stall `with_body` or run out of memory. It isn't rejected, because pact_ffi accepts it.
- [ ] pact_ffi silently drops a form value whose matcher fails to build (e.g. `regex` without `"regex"`).
- [ ] Query and header values of `[]` drop the parameter silently.
- [ ] `PactEx.Error.message/1` repeats the code twice ("… failed with code 1 (code 1)").
- [ ] Rust cleanups:
  - the `Created` wrapper is redundant, since the `Result` encoder already does its job;
  - the `Outcome` encoder has an unneeded `clone`;
  - `arg_cstring` and `port_arg` are not in `args.rs`.
- [ ] `String.trim/1` and Rust's `str::trim` may disagree on some Unicode whitespace (log file paths).
- [ ] Consider accepting keyword lists for `headers:` and `query:`, since Req users write them that way.
- [ ] Replace `unless` in `PactEx.Matchers` (soft-deprecated style).
- [ ] The pact_models matcher-expression parser (`matching(...)` strings) has not been audited for panics.

## Minor: tests

- [ ] Abort matrix: assert `length(expected) == length(headers)` per row (`Enum.zip` silently truncates); fix the comment reason at `abort_cases.ex` ~190 (Mime doesn't parse the JSON-text header at all).
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

## Minor: docs

- [ ] README: make the "sniffed as JSON" wording precise. pact_models' regex needs `{` followed by `}` or `"\w`, and allows leading Unicode whitespace.
- [ ] README: the glibc 2.34 floor is measured for x86_64-gnu only. aarch64-gnu is built in a cross image.
- [ ] The error message for valid JSON nested deeper than serde_json's limit of 128 says "not valid JSON". Mention the nesting limit.
- [ ] The `@spec` of `will_respond_with/3` and the `Response` `@type` say `pos_integer()`. The guard is `100..599`.
- [ ] The `regex/2` doc should justify `term()` values with non-string JSON body values.
- [ ] RELEASING: the note on SHA pins should mention that `dtolnay/rust-toolchain` is pinned to a branch head.

## Before the first release

- [ ] release.yml hardening: run `readelf` outside the `|| true` so a readelf failure fails the step; add `startsWith(github.ref, 'refs/tags/v')` to `publish`'s `if:`; add a `concurrency` group for PR dry runs; consider adding `lib/pact_ex/native.ex` to the `pull_request` paths. Note the x86_64 glibc limit can't trip on ubuntu-22.04 (guard only).
- [ ] RELEASING.md: dry run skips the tag-vs-`@version` check; replace the stale `objdump -T` mention with `readelf -W --dyn-syms`; document recovery when one build leg fails on a tag push (re-run failed jobs).
- [ ] `content_type.rs` ~68: the `debug!` cost only applies when a debug subscriber is installed.
- [ ] Confirm the source URL `https://github.com/arctarus/pact_ex` in `mix.exs` and `lib/pact_ex/native.ex`.
- [ ] Dry-run `release.yml`, e.g. with `workflow_dispatch` or a test tag.

## Before plan 2

- [ ] Re-review plans 2 and 3 against the real plan 1 code.
- [ ] Add plugin cleanup to the pact resource lifecycle.
- [ ] Expect a different mismatch JSON shape from plugin mock servers.
