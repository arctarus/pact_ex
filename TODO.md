# TODO

Open issues from the plan 1 and plan 2 reviews. Done items are removed. The history is in git and in the SDD ledger, which is git-ignored.

## Minor: code

- [ ] Consider an upstream issue for pact-reference: pact_models `calc_content_type` (`v4/mod.rs:68`) indexes `v[0]` of a Content-Type header without a bounds check, so an empty header aborts the process.
- [ ] The pact_models matcher-expression parser (`matching(...)` strings) has not been audited for panics.

## Minor: tests

- [ ] `large_body_test.exs`: the `dirty > 0` assertion could false-pass on an unrelated dirty GC. Comparing with a tiny scan did not work: the busy time counts all dirty CPU work in the VM, and on macOS the noise of a tiny scan was larger than the cost of a big one (CI failed on both macOS jobs). Needs another way to tell where a NIF ran.
- [ ] Builder tests whose loops don't name the failing value: `assert_raise ArgumentError` inside a `for` (for example the `argument validation` loops in `http_test.exs`) fails without saying which input. Also, an out-of-range port and a NUL byte raise a bare `argument error` from the NIF (`BadArg`), so their tests cannot assert a message. Give those errors a message, or accept it.
- [ ] Test-support modules (`PactFile`, `AnimalClient`, `PluginProcesses`, `CollidingRoot`) are in the global namespace. Plan 3 adds `AnimalInteractions`, `AnimalProvider`, `Broker`, `GrpcInteractions` and two gRPC servers there too, and `PactEx.SchedulerStats` and `PactEx.MissingPluginDir` already use `PactEx.`. Decide before plan 3 starts: namespace them all (for example `PactEx.Test.*`), or drop this item. `consumer_test.exs` keeps its own `read_pact`.
