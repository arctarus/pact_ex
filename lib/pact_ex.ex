defmodule PactEx do
  @moduledoc """
  Pact contract testing for Elixir, built on the `pact_ffi` Rust library.
  """

  @doc """
  Creates a pact between `consumer` and `provider`.

  See `PactEx.Pact.new/3` for the options. Raises `FunctionClauseError` if
  `consumer` or `provider` is not a string.
  """
  @spec new(String.t(), String.t(), keyword()) :: PactEx.Pact.t()
  defdelegate new(consumer, provider, opts \\ []), to: PactEx.Pact
end
