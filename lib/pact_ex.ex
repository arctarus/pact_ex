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

  @doc """
  Adds the plugin `name` to `pact`.

  See `PactEx.Pact.using_plugin/3`. Raises `ArgumentError` if the pact already
  uses a plugin with that name.
  """
  @spec using_plugin(PactEx.Pact.t(), String.t(), String.t() | nil) :: PactEx.Pact.t()
  defdelegate using_plugin(pact, name, version \\ nil), to: PactEx.Pact
end
