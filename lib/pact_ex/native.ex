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

  def new_pact(_consumer, _provider), do: :erlang.nif_error(:nif_not_loaded)
  def with_specification(_pact, _spec), do: :erlang.nif_error(:nif_not_loaded)
  def new_interaction(_pact, _description), do: :erlang.nif_error(:nif_not_loaded)
  def given(_interaction, _state), do: :erlang.nif_error(:nif_not_loaded)

  def given_with_params(_interaction, _state, _params_json),
    do: :erlang.nif_error(:nif_not_loaded)

  def with_request(_interaction, _method, _path), do: :erlang.nif_error(:nif_not_loaded)

  def with_query_parameter(_interaction, _name, _index, _value),
    do: :erlang.nif_error(:nif_not_loaded)

  def with_header(_interaction, _part, _name, _index, _value),
    do: :erlang.nif_error(:nif_not_loaded)

  def with_body(_interaction, _part, _content_type, _body),
    do: :erlang.nif_error(:nif_not_loaded)

  def with_binary_body(_interaction, _part, _content_type, _body),
    do: :erlang.nif_error(:nif_not_loaded)

  def response_status(_interaction, _status), do: :erlang.nif_error(:nif_not_loaded)

  def create_mock_server(_pact, _host, _port, _transport, _config_json),
    do: :erlang.nif_error(:nif_not_loaded)

  def mock_server_matched(_port), do: :erlang.nif_error(:nif_not_loaded)
  def mock_server_mismatches(_port), do: :erlang.nif_error(:nif_not_loaded)

  def write_pact_file(_port, _dir, _overwrite), do: :erlang.nif_error(:nif_not_loaded)
  def cleanup_mock_server(_port), do: :erlang.nif_error(:nif_not_loaded)
end
