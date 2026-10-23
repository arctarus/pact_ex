defmodule PactEx.HTTP.Response do
  @moduledoc """
  The response half of an HTTP interaction.
  """

  @enforce_keys [:status]
  defstruct status: nil, headers: %{}, body: nil, content_type: nil

  @type t :: %__MODULE__{
          status: 100..599,
          headers: %{String.t() => term()},
          body: term(),
          content_type: String.t() | nil
        }
end
