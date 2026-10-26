defmodule PactEx.Error do
  @moduledoc """
  An error raised or returned by the native Pact library, or by `PactEx`
  while preparing input for it.

  Fields:

    * `:function` - the `pactffi_*` function that failed, or the `PactEx`
      function that rejected the input.
    * `:code` - the numeric error code. `-100` means an argument contained a
      NUL byte. `-101` means `PactEx` rejected an interaction before calling
      the native library, for example a missing request or an unsupported
      value type.
    * `:message` - a description of the failure.
  """

  defexception [:function, :code, :message]

  @type t :: %__MODULE__{function: String.t(), code: integer(), message: String.t()}

  @doc """
  Builds an error from the map a native function returns.

  Raises `FunctionClauseError` if the map lacks `:function`, `:code` or `:message`.
  """
  @spec from_native(%{function: String.t(), code: integer(), message: String.t()}) :: t()
  def from_native(%{function: function, code: code, message: message}) do
    %__MODULE__{function: function, code: code, message: message}
  end

  @impl true
  def message(%__MODULE__{function: function, code: code, message: message})
      when is_binary(function) do
    cond do
      # The native fallback message is "<function> failed with code <code>",
      # so it already shows the code and the function.
      is_binary(message) and String.starts_with?(message, function) and
          mentions_code?(message, code) ->
        message

      is_binary(message) and String.starts_with?(message, function) ->
        "#{message} (code #{code})"

      true ->
        "#{function} failed with code #{code}: #{message}"
    end
  end

  # Raised with a bare message, as in `raise PactEx.Error, "boom"`.
  def message(%__MODULE__{message: message}) when is_binary(message), do: message
  def message(%__MODULE__{}), do: "PactEx error"

  # "code 1" must not match "code 10".
  defp mentions_code?(message, code), do: Regex.match?(~r/\bcode #{code}\b/, message)
end
