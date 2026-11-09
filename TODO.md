# TODO

Open issues from the plan 1 and plan 2 reviews. Done items are removed. The history is in git and in the SDD ledger, which is git-ignored.

## Minor: code

- [ ] Consider an upstream issue for pact-reference: pact_models `calc_content_type` (`v4/mod.rs:68`) indexes `v[0]` of a Content-Type header without a bounds check, so an empty header aborts the process.
- [ ] The pact_models matcher-expression parser (`matching(...)` strings) has not been audited for panics.

## Minor: tests

- [ ] `large_body_test.exs`: the `dirty > 0` assertion could false-pass on an unrelated dirty GC. Comparing with a tiny scan did not work: the busy time counts all dirty CPU work in the VM, and on macOS the noise of a tiny scan was larger than the cost of a big one (CI failed on both macOS jobs). Needs another way to tell where a NIF ran.
- [ ] Builder tests whose loops don't name the failing value: `assert_raise ArgumentError` inside a `for` (for example the `argument validation` loops in `http_test.exs`) fails without saying which input. Also, an out-of-range port and a NUL byte raise a bare `argument error` from the NIF (`BadArg`), so their tests cannot assert a message. Give those errors a message, or accept it.
- [ ] Move the older test-support modules from the global namespace to `PactEx.Test` (new ones already go there, see plan 3). Each move renames the module, its file under `test/support/`, and every use (add an alias, Credo's `AliasUsage` asks for it):
  - `PactFile` (`test/support/pact_file.ex`)
  - `AnimalClient` (`test/support/animal_client.ex`)
  - `PluginProcesses` (`test/support/plugin_processes.ex`)
  - `CollidingRoot` (`test/support/colliding_root.ex`)
  - `PactEx.AbortCases` (`test/support/abort_cases.ex`) to `PactEx.Test.AbortCases`
  - `consumer_test.exs` keeps its own `read_pact`: use `PactFile` there.
  `Routeguide.*` (`test/support/route_guide.ex`) is generated gRPC code and stays.
