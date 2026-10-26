defmodule PactEx.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/arctarus/pact_ex"

  def project do
    [
      app: :pact_ex,
      version: @version,
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: "Pact contract testing for Elixir, built on the pact_ffi Rust library.",
      package: package(),
      dialyzer: [
        # Cached in CI, see .github/workflows/ci.yml.
        plt_local_path: "priv/plts/project",
        plt_core_path: "priv/plts/core",
        flags: [:error_handling, :unmatched_returns, :extra_return, :missing_return]
      ],
      source_url: @source_url,
      docs: [
        main: "readme",
        extras: ["README.md", "ARCHITECTURE.md", "CHANGELOG.md"],
        source_ref: "v#{@version}"
      ]
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]

  defp deps do
    [
      {:rustler_precompiled, "~> 0.10"},
      {:rustler, "~> 0.38", optional: true},
      {:req, "~> 0.5", only: :test},
      {:ex_doc, ">= 0.0.0", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      files:
        ~w(lib native/pact_ex_nif/src native/pact_ex_nif/Cargo.toml native/pact_ex_nif/Cargo.lock native/pact_ex_nif/.cargo checksum-*.exs mix.exs README.md ARCHITECTURE.md CHANGELOG.md LICENSE)
    ]
  end
end
