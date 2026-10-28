defmodule PactEx.SyncMessage.Generated do
  @moduledoc """
  The contents of a synchronous message as a consumer would see them: matchers
  are replaced by their example values.

  Fields:

    * `:request` - the request contents.
    * `:responses` - the response contents, in the order they were added.
    * `:transport` - `nil` when the message runs without a transport.
      Otherwise a map with the `:port` and the `:address` of the transport the
      plugin started. The address is `"<host>:<port>"`, the target a gRPC
      client connects to, with an IPv6 host in brackets (`"[::1]:50051"`).
      It is not a URL: a plugin transport has no `http://` scheme.

  Request and response contents follow the rules of `PactEx.Message.Reified`:
  for a JSON content type they are the decoded JSON, and for any other type
  they are the raw bytes. A request or response without contents is `nil`.
  """

  alias PactEx.Message.Reified

  defstruct request: nil, responses: [], transport: nil

  @type t :: %__MODULE__{
          request: term(),
          responses: [term()],
          transport: %{port: pos_integer(), address: String.t()} | nil
        }

  @doc false
  # Decodes the string `pactffi_sync_message_generate_contents` returns:
  # `{"request": {"contents": <envelope>}, "response": [{"contents": <envelope>}]}`.
  # A part without contents has no `contents` key, and the envelope itself can
  # be null or empty.
  @spec from_json(String.t()) :: t()
  def from_json(json) do
    decoded = JSON.decode!(json)

    %__MODULE__{
      request: part_contents(Map.get(decoded, "request")),
      responses: decoded |> Map.get("response") |> List.wrap() |> Enum.map(&part_contents/1)
    }
  end

  defp part_contents(%{"contents" => envelope}) when envelope == %{}, do: nil

  defp part_contents(%{"contents" => envelope}) do
    {contents, _content_type} = Reified.decode_contents(envelope)
    contents
  end

  defp part_contents(_part), do: nil
end
