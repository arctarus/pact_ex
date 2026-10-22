defmodule PactEx.Pact do
  @moduledoc """
  A pact between one consumer and one provider.

  Build it with `PactEx.new/3`.
  """

  @enforce_keys [:consumer, :provider]
  defstruct consumer: nil, provider: nil, spec: :v4, pact_dir: "pacts"

  @type spec :: :v2 | :v3 | :v4

  @type t :: %__MODULE__{
          consumer: String.t(),
          provider: String.t(),
          spec: spec(),
          pact_dir: Path.t()
        }

  @specs [:v2, :v3, :v4]

  @doc """
  Creates a pact for `consumer` and `provider`.

  ## Options

    * `:spec` - Pact specification, one of `:v2`, `:v3` or `:v4`. Defaults to `:v4`.
    * `:pact_dir` - Directory where the pact file is written. Defaults to `"pacts"`.

  Raises `ArgumentError` on unknown options or an invalid `:spec`. Raises
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

    %__MODULE__{
      consumer: consumer,
      provider: provider,
      spec: spec,
      pact_dir: Keyword.fetch!(opts, :pact_dir)
    }
  end
end
