defmodule PactEx.VerificationError do
  @moduledoc """
  A provider verification that did not pass. Returned by `PactEx.Verifier.verify/1`
  and raised by `PactEx.Verifier.verify!/1`.

  Fields:

    * `:exit_code` - the code of the native verifier: `1` when a verification
      failed, `2` when it could not run (for example a pact that cannot be
      read, or a plugin that failed to load), and `0` when it passed but verified
      nothing (see the `:no_pacts_is_error` option).
    * `:report` - the report of the verifier, decoded. `"errors"` lists each
      failure as `%{"interaction" => description, "mismatch" => details}`, and
      `"interactionResults"` has the result of each interaction.
    * `:output` - the text the verifier printed, without colours.
    * `:callback_errors` - the reasons that your state handler or message
      providers gave when they failed, in the order they happened. The verifier
      itself reports only a status code for those.
  """

  defexception exit_code: 1, report: %{}, output: "", callback_errors: []

  @type t :: %__MODULE__{
          exit_code: integer(),
          report: map(),
          output: String.t(),
          callback_errors: [String.t()]
        }

  @impl true
  def message(%__MODULE__{} = error) do
    failures = error.report |> Map.get("errors", []) |> Enum.map(&failure/1)

    case failures ++ callbacks(error.callback_errors) do
      [] -> no_details(error)
      lines -> Enum.join(["provider verification failed:" | lines], "\n")
    end
  end

  defp failure(%{"interaction" => description, "mismatch" => mismatch}) do
    "  * #{description}: #{summary(mismatch)}"
  end

  defp failure(other), do: "  * #{inspect(other)}"

  defp summary(%{"type" => "error", "message" => message}), do: message

  defp summary(%{"type" => "mismatches", "mismatches" => mismatches}),
    do: Enum.map_join(mismatches, "; ", &mismatch/1)

  defp summary(other), do: inspect(other)

  defp mismatch(%{"mismatch" => text}), do: text

  defp mismatch(%{"type" => type} = mismatch),
    do: "#{type} #{inspect(Map.delete(mismatch, "type"))}"

  defp mismatch(other), do: inspect(other)

  defp callbacks([]), do: []
  defp callbacks(errors), do: ["callbacks that failed:" | Enum.map(errors, &"  * #{&1}")]

  # Exit code 2, and a pass that verified nothing, have no failing interaction.
  defp no_details(%__MODULE__{exit_code: 0}),
    do: "provider verification verified no interaction, so there was nothing to pass"

  defp no_details(%__MODULE__{output: output}) when output not in ["", nil],
    do: "provider verification failed:\n" <> output

  defp no_details(%__MODULE__{exit_code: code}),
    do: "provider verification failed with exit code #{code}"
end
