defmodule PactEx.HTTP.Request do
  @moduledoc """
  The request half of an HTTP interaction.
  """

  @enforce_keys [:method, :path]
  defstruct method: nil, path: nil, query: %{}, headers: %{}, body: nil, content_type: nil

  @type t :: %__MODULE__{
          method: String.t(),
          path: String.t() | map(),
          query: %{String.t() => term()},
          headers: %{String.t() => term()},
          body: term(),
          content_type: String.t() | nil
        }
end
