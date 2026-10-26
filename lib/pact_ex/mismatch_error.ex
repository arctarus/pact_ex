defmodule PactEx.MismatchError do
  @moduledoc """
  The mock server did not see the requests the interactions describe.

  `:mismatches` holds the decoded mismatch maps reported by the native
  library. The most common `"type"` values are:

    * `"missing-request"` - an expected request never arrived.
    * `"request-not-found"` - a request arrived that no interaction expects.
    * `"request-mismatch"` - a request matched a path and method but not the
      rest. Its `"mismatches"` key lists the differences.
  """

  defexception mismatches: []

  @type t :: %__MODULE__{mismatches: [map()]}

  @impl true
  def message(%__MODULE__{mismatches: []}), do: "Pact mock server reported a mismatch"

  def message(%__MODULE__{mismatches: mismatches}) do
    lines = Enum.map(mismatches, &describe/1)
    Enum.join(["Pact mock server reported #{length(mismatches)} mismatch(es):" | lines], "\n")
  end

  defp describe(mismatch) do
    head =
      ["type", "method", "path"]
      |> Enum.map(&Map.get(mismatch, &1))
      |> Enum.reject(&is_nil/1)
      |> Enum.join(" ")

    details =
      mismatch
      |> Map.get("mismatches", [])
      |> List.wrap()
      |> Enum.flat_map(fn
        %{"mismatch" => text} when is_binary(text) -> ["\n      " <> text]
        _other -> []
      end)

    "  - " <> head <> Enum.join(details)
  end
end
