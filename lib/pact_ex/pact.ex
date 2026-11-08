defmodule PactEx.Pact do
  @moduledoc """
  A pact between one consumer and one provider.

  Build it with `PactEx.new/3`.
  """

  @enforce_keys [:consumer, :provider]
  defstruct consumer: nil, provider: nil, spec: :v4, pact_dir: "pacts", plugins: []

  @type spec :: :v2 | :v3 | :v4

  @type t :: %__MODULE__{
          consumer: String.t(),
          provider: String.t(),
          spec: spec(),
          pact_dir: Path.t(),
          plugins: [{String.t(), String.t() | nil}]
        }

  @specs [:v2, :v3, :v4]

  @doc """
  Creates a pact for `consumer` and `provider`.

  ## Options

    * `:spec` - Pact specification, one of `:v2`, `:v3` or `:v4`. Defaults to `:v4`.
    * `:pact_dir` - Directory where the pact file is written. Defaults to `"pacts"`.

  Raises `ArgumentError` on unknown options, an invalid `:spec` or a `:pact_dir`
  that is not a non-empty string. Raises
  `FunctionClauseError` if `consumer` or `provider` is not a string.
  """
  @spec new(String.t(), String.t(), keyword()) :: t()
  def new(consumer, provider, opts \\ []) when is_binary(consumer) and is_binary(provider) do
    opts = Keyword.validate!(opts, spec: :v4, pact_dir: "pacts")

    spec = Keyword.fetch!(opts, :spec)

    unless spec in @specs do
      raise ArgumentError,
            "invalid :spec #{inspect(spec)}, expected one of #{inspect(@specs)}"
    end

    pact_dir = Keyword.fetch!(opts, :pact_dir)

    unless is_binary(pact_dir) and pact_dir != "" do
      raise ArgumentError,
            "invalid :pact_dir #{inspect(pact_dir)}, expected a non-empty string"
    end

    %__MODULE__{consumer: consumer, provider: provider, spec: spec, pact_dir: pact_dir}
  end

  @doc """
  Adds the plugin `name` to the pact.

  The plugin is loaded when a mock server or a message test starts, and it is
  needed for any `PactEx.Plugin.contents/2` body. `version` is the plugin
  version, or `nil` to let the plugin driver choose one.

  Raises `ArgumentError` if the pact already has a plugin with that name,
  whatever its version. Every load adds one use of the plugin, but the cleanup
  of a pact removes one use per plugin name, so a plugin loaded twice would
  never exit.
  """
  @spec using_plugin(t(), String.t(), String.t() | nil) :: t()
  def using_plugin(%__MODULE__{plugins: plugins} = pact, name, version \\ nil)
      when is_binary(name) and (is_binary(version) or is_nil(version)) do
    if List.keymember?(plugins, name, 0) do
      raise ArgumentError, "the pact already uses the plugin #{inspect(name)}"
    end

    %{pact | plugins: plugins ++ [{name, version}]}
  end
end
