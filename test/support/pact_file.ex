defmodule PactFile do
  @moduledoc """
  Reads a written pact file. Test support only.
  """

  @doc """
  Reads and decodes `<consumer>-<provider>.json` from `dir`.
  """
  @spec read!(Path.t(), {String.t(), String.t()}) :: map()
  def read!(dir, {consumer, provider}) do
    dir |> Path.join("#{consumer}-#{provider}.json") |> File.read!() |> JSON.decode!()
  end
end
