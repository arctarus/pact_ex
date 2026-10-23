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
   not match `@version`. Wait for all 12 jobs (6 targets, NIF 2.16 and 2.17) to
   finish. Each job uploads one `.tar.gz` to the GitHub release.
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
  annotated tag, the commit it points to) and change both.
- The `x86_64-unknown-linux-gnu` NIF is built natively on `ubuntu-22.04` and
  needs glibc 2.34 or later (`objdump -T libpact_ex_nif.so | grep GLIBC_`). The
  README says so. Keep the two in sync if the runner changes.
- `rust-version` in `native/pact_ex_nif/Cargo.toml` follows the locked
  `rustler`. Check it when you update `Cargo.lock`.
