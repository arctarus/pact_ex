defmodule PactEx.MismatchError do
  @moduledoc """
  The mock server did not see the requests the interactions describe.

  `:mismatches` holds the decoded mismatch maps reported by the native
  library. The most common `"type"` values are:

    * `"missing-request"` - an expected request never arrived.
    * `"request-not-found"` - a request arrived that no interaction expects.
    * `"request-mismatch"` - a request matched a path and method but not the
      rest. Its `"mismatches"` key lists the differences.

  A mock server provided by a plugin reports mismatches with `"path"`,
  `"error"` and `"mismatches"` keys, and no `"type"` or `"method"`.
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

    head = with_error(head, Map.get(mismatch, "error"))

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

  # Mismatches from a plugin mock server have no "type" or "method". Their
  # "error" is often the only explanation, so show it after the path. The
  # plugin driver always sends it, as "" when there is no error.
  defp with_error(head, ""), do: head
  defp with_error(head, error) when is_binary(error) and head != "", do: head <> ": " <> error
  defp with_error(_head, error) when is_binary(error), do: error
  defp with_error(head, _error), do: head
end
