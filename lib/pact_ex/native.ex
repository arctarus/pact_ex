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

  # The types below mirror the Rust signatures in native/pact_ex_nif/src.
  @typep pact :: reference()
  @typep interaction :: reference()
  @typep part :: :request | :response
  @typep ffi_error :: %{function: String.t(), code: integer(), message: String.t()}
  @typep outcome :: :ok | {:error, ffi_error()}

  @spec version() :: String.t()
  def version, do: :erlang.nif_error(:nif_not_loaded)

  @spec new_pact(String.t(), String.t()) :: pact()
  def new_pact(_consumer, _provider), do: :erlang.nif_error(:nif_not_loaded)

  @spec with_specification(pact(), PactEx.Pact.spec()) :: outcome()
  def with_specification(_pact, _spec), do: :erlang.nif_error(:nif_not_loaded)

  @spec new_interaction(pact(), String.t()) :: interaction()
  def new_interaction(_pact, _description), do: :erlang.nif_error(:nif_not_loaded)

  @spec given(interaction(), String.t()) :: outcome()
  def given(_interaction, _state), do: :erlang.nif_error(:nif_not_loaded)

  @spec given_with_params(interaction(), String.t(), String.t()) :: outcome()
  def given_with_params(_interaction, _state, _params_json),
    do: :erlang.nif_error(:nif_not_loaded)

  @spec with_request(interaction(), String.t(), String.t()) :: outcome()
  def with_request(_interaction, _method, _path), do: :erlang.nif_error(:nif_not_loaded)

  @spec with_query_parameter(interaction(), String.t(), non_neg_integer(), String.t()) ::
          outcome()
  def with_query_parameter(_interaction, _name, _index, _value),
    do: :erlang.nif_error(:nif_not_loaded)

  @spec with_header(interaction(), part(), String.t(), non_neg_integer(), String.t()) ::
          outcome()
  def with_header(_interaction, _part, _name, _index, _value),
    do: :erlang.nif_error(:nif_not_loaded)

  @spec with_body(interaction(), part(), String.t(), String.t()) :: outcome()
  def with_body(_interaction, _part, _content_type, _body),
    do: :erlang.nif_error(:nif_not_loaded)

  @spec with_binary_body(interaction(), part(), String.t(), binary()) :: outcome()
  def with_binary_body(_interaction, _part, _content_type, _body),
    do: :erlang.nif_error(:nif_not_loaded)

  @spec response_status(interaction(), String.t()) :: outcome()
  def response_status(_interaction, _status), do: :erlang.nif_error(:nif_not_loaded)

  @spec create_mock_server(pact(), String.t(), 0..65_535, String.t(), String.t() | nil) ::
          {:ok, 1..65_535} | {:error, ffi_error()}
  def create_mock_server(_pact, _host, _port, _transport, _config_json),
    do: :erlang.nif_error(:nif_not_loaded)

  @spec mock_server_matched(0..65_535) :: boolean()
  def mock_server_matched(_port), do: :erlang.nif_error(:nif_not_loaded)

  @spec mock_server_mismatches(0..65_535) :: String.t() | nil
  def mock_server_mismatches(_port), do: :erlang.nif_error(:nif_not_loaded)

  @spec content_type_kind(String.t()) :: :xml | :form | :json | :other | :invalid
  def content_type_kind(_content_type), do: :erlang.nif_error(:nif_not_loaded)

  @spec detect_json(String.t()) :: boolean()
  def detect_json(_text), do: :erlang.nif_error(:nif_not_loaded)

  @spec json_text_shape(String.t()) :: {:object, String.t()} | :other | :invalid | :too_deep
  def json_text_shape(_text), do: :erlang.nif_error(:nif_not_loaded)

  @spec init_logger(String.t(), :off | :error | :warn | :info | :debug | :trace) :: outcome()
  def init_logger(_sink, _level), do: :erlang.nif_error(:nif_not_loaded)

  @spec write_pact_file(0..65_535, String.t(), boolean()) :: outcome()
  def write_pact_file(_port, _dir, _overwrite), do: :erlang.nif_error(:nif_not_loaded)

  @spec cleanup_mock_server(0..65_535) :: boolean()
  def cleanup_mock_server(_port), do: :erlang.nif_error(:nif_not_loaded)

  @spec new_message_interaction(pact(), String.t()) :: interaction()
  def new_message_interaction(_pact, _description), do: :erlang.nif_error(:nif_not_loaded)

  @spec new_sync_message_interaction(pact(), String.t()) :: interaction()
  def new_sync_message_interaction(_pact, _description), do: :erlang.nif_error(:nif_not_loaded)

  @spec with_metadata(interaction(), String.t(), String.t(), part()) :: outcome()
  def with_metadata(_interaction, _key, _value, _part), do: :erlang.nif_error(:nif_not_loaded)

  @spec message_reify(interaction()) :: {:ok, String.t()} | {:error, ffi_error()}
  def message_reify(_interaction), do: :erlang.nif_error(:nif_not_loaded)

  @spec sync_message_generate_contents(interaction()) :: {:ok, String.t()} | {:error, ffi_error()}
  def sync_message_generate_contents(_interaction), do: :erlang.nif_error(:nif_not_loaded)

  @spec pact_handle_write_file(pact(), String.t(), boolean()) :: outcome()
  def pact_handle_write_file(_pact, _dir, _overwrite), do: :erlang.nif_error(:nif_not_loaded)

  @spec using_plugin(pact(), String.t(), String.t() | nil) :: outcome()
  def using_plugin(_pact, _name, _version), do: :erlang.nif_error(:nif_not_loaded)

  @spec interaction_contents(interaction(), part(), String.t(), String.t()) :: outcome()
  def interaction_contents(_interaction, _part, _content_type, _contents_json),
    do: :erlang.nif_error(:nif_not_loaded)

  @spec cleanup_plugins(pact()) :: boolean()
  def cleanup_plugins(_pact), do: :erlang.nif_error(:nif_not_loaded)
end
