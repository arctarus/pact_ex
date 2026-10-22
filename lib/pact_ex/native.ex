defmodule PactEx.Native do
  @moduledoc false

  version = Mix.Project.config()[:version]

  use RustlerPrecompiled,
    otp_app: :pact_ex,
    crate: "pact_ex_nif",
    version: version,
    base_url: "https://github.com/arctarus/pact_ex/releases/download/v#{version}",
    force_build:
      System.get_env("PACT_EX_BUILD") in ["1", "true"] or
        Application.compile_env(:rustler_precompiled, [:force_build, :pact_ex], false),
    targets: ~w(
      aarch64-apple-darwin
      x86_64-apple-darwin
      aarch64-unknown-linux-gnu
      x86_64-unknown-linux-gnu
      aarch64-unknown-linux-musl
      x86_64-unknown-linux-musl
    ),
    nif_versions: ["2.16", "2.17"]

  def version, do: :erlang.nif_error(:nif_not_loaded)
end
