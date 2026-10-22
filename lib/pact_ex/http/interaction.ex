defmodule PactEx.HTTP.Interaction do
  @moduledoc """
  A single HTTP interaction: provider states, one request and one response.

  Build it with the functions in `PactEx.HTTP`.
  """

  alias PactEx.HTTP.{Request, Response}

  @enforce_keys [:description]
  defstruct description: nil, provider_states: [], request: nil, response: nil

  @type t :: %__MODULE__{
          description: String.t(),
          provider_states: [{String.t(), map() | nil}],
          request: Request.t() | nil,
          response: Response.t() | nil
        }
end
