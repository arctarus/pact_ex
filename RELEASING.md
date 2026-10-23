# Releasing

Users download a precompiled NIF from the GitHub release that matches the
package version. `release.yml` builds and uploads those files. The checksums go
into the Hex package.

Before the first release, confirm that `https://github.com/arctarus/pact_ex` is
the final repository URL. It is set in `mix.exs` (`@source_url`) and in
`lib/pact_ex/native.ex` (`base_url`). If the repository moves after a release,
old versions still download from the old URL.

1. Bump `@version` in `mix.exs` and add the version to `CHANGELOG.md`. Commit.
2. Push the commit to `main` and wait for CI to pass. Do not tag a commit that
   has not passed CI.
3. Tag the commit `vX.Y.Z` and push the tag. `release.yml` fails if the tag does
   not match `@version`. Wait for the 12 build jobs (6 targets, NIF 2.16 and
   2.17) and the `publish` job to finish. `publish` runs only when every build
   job passed, and uploads the 12 `.tar.gz` files to the GitHub release in one
   step.
4. Generate the checksum file:

   ```sh
   mix rustler_precompiled.download PactEx.Native --all --print
   ```

   This writes `checksum-Elixir.PactEx.Native.exs` and prints the checksums.
5. Commit the checksum file and push it. It is in the Hex package `files`, so
   publish only after it is committed and pushed.
6. Publish:

   ```sh
   mix hex.publish
   ```

   Run `mix hex.build --unpack -o /tmp/pact_ex_pkg` first to inspect the package.
   It fails with `Missing files: checksum-*.exs` until step 4 has produced the
   checksum file.
   It must contain `lib/`, `native/pact_ex_nif/src`, `Cargo.toml`, `Cargo.lock`,
   `.cargo/config.toml` and the checksum file, and must not contain `target/` or
   `priv/`.

## Dry run

`release.yml` also runs without a tag, and then it publishes nothing. It builds
the same 12 files, runs the same checks and keeps the tarballs as workflow
artifacts for 7 days. The version in their names is `@version` from `mix.exs`.
A dry run starts:

- on a pull request that touches `native/**`, `mix.exs`, `lib/pact_ex/native.ex`
  or `.github/workflows/release.yml`;
- by hand: Actions, "Release precompiled NIFs", "Run workflow", on any branch
  (the workflow file must exist on the default branch for the button to show).

Run one before the first release, and after any change to the pipeline. The
`publish` job is skipped: it needs a `v*` tag push. To test the release itself,
tag a throwaway version on a fork.

A dry run does not check the tag against `@version`, because there is no tag.
It names the files after `@version`. So a dry run cannot catch a tag that does
not match: only the tag push fails on that, before it builds anything.

A new push to a branch or pull request cancels the dry run that is still going
for it. A tag push is never cancelled.

## If a build job fails on a tag push

`fail-fast` is off, so the other build jobs finish, and `publish` does not run.
Nothing is released. Find the cause first, then pick one:

- a flaky failure (a runner or network error): open the run in Actions and
  choose "Re-run failed jobs". The jobs that passed keep their artifacts, and
  once every build job has passed, `publish` runs and uploads all 12 files.
  The artifacts are kept for `retention-days: 7`. After that a re-run builds
  only the failed jobs, `publish` finds fewer than 12 files and fails its
  check. Then push a new tag, or choose "Re-run all jobs";
- a real failure: fix it on `main`, delete the tag locally and on the remote,
  and tag the new commit with the same version. Do this only if nothing was
  published. A re-run uses the commit the tag pointed to when it was pushed,
  so it cannot pick up a fix.

Check the GitHub release before publishing to Hex: it must list all 12 files.

## Check the glibc floor

The two `*-unknown-linux-gnu` jobs print the highest `GLIBC_x.y` symbol version
that the NIF needs (`readelf -W --dyn-syms`), and add it to the run summary.
The x86_64 job fails when it is above `GLIBC_2.35`, the glibc of the
`ubuntu-22.04` runner. The aarch64 job is built in a cross image, so it only
reports. A failure of `readelf` itself fails the step; only a library with no
`GLIBC_` symbol at all is accepted (it prints `none`). The x86_64 limit is a
guard: it cannot trip on `ubuntu-22.04` today, because that runner has the
limit's own glibc. The first dry run (2026-10-23) measured `GLIBC_2.34` for x86_64 and
`GLIBC_2.18` for aarch64, as the README states. If a run reports different
values, update the README and the note below.

## Check the artifact contents

Each tarball must hold only `libpact_ex_nif-vX.Y.Z-nif-N-<target>.so`. A local
build also copies `pact_ffi`'s own cdylib to `priv/native/pact_ffi.so`, because
`pact_ffi` declares `crate-type = ["cdylib", "staticlib", "rlib"]`. That copy
is a local artifact only. `philss/rustler-precompiled-action` packages only
`lib<project-name>.so` or `.dylib`, and `release.yml` lists the tarball and
fails if it holds anything else. `priv/` is git-ignored and not in the package.

## Notes

- The NIF version comes from the `nif_version_2_16` and `nif_version_2_17`
  features in `native/pact_ex_nif/Cargo.toml`. The release action selects them.
  Keep them in sync with `nif_versions` in `lib/pact_ex/native.ex`.
- `pact_ffi` and `pact_models` are pinned exactly. Upgrade them together, in a
  dedicated pull request.
- The `x86_64-apple-darwin` job runs on `macos-15-intel`. GitHub retired
  `macos-13`.
- `Cargo.lock` is committed and shipped. Do not remove it.
- The workflows pin third-party actions by commit SHA, with the tag in a
  trailing comment. To update one, resolve the new tag to its commit (for an
  annotated tag, the commit it points to) and change both. The exception is
  `dtolnay/rust-toolchain`. The ref you pin selects the toolchain, so its
  `stable` branch is pinned by the commit at its head, and the comment says
  `stable`. Its `v1` tag and `master` branch need a `toolchain:` input, which
  `ci.yml` and `release.yml` do not pass. To update it, resolve `stable` to its
  current commit.
- The `x86_64-unknown-linux-gnu` NIF is built natively on `ubuntu-22.04` and
  needs glibc 2.34 or later; the `aarch64-unknown-linux-gnu` NIF needs 2.18
  (`readelf -W --dyn-syms libpact_ex_nif.so | grep -o 'GLIBC_[0-9.]*' | sort -V | tail -1`).
  The README says so. Keep the two in sync if the runner or cross image changes.
- `rust-version` in `native/pact_ex_nif/Cargo.toml` follows the locked
  `rustler`. Check it when you update `Cargo.lock`.
