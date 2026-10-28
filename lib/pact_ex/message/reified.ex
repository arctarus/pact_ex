defmodule PactEx.Message.Reified do
  @moduledoc """
  A message as a provider would send it: matchers are replaced by their example
  values.

  Fields:

    * `:contents` - for a JSON content type, the decoded JSON (maps, lists,
      numbers and so on), and `nil` for JSON `null`. For any other content
      type, the raw bytes: a string for text, a binary for binary contents.
      Text with a JSON content type that is not valid JSON is raw bytes too.
    * `:metadata` - the metadata of the message, as a map of decoded JSON. It
      includes the keys that pact_ffi adds, such as `contentType`.
    * `:content_type` - the content type of the contents, or `nil` when there
      are none.

  An empty body, such as zero-byte plugin contents (a protobuf message with
  only default fields), gives `contents: ""` and `metadata: %{}`.
  """

  defstruct contents: nil, metadata: %{}, content_type: nil

  @type t :: %__MODULE__{
          contents: term(),
          metadata: map(),
          content_type: String.t() | nil
        }

  @doc false
  # Decodes the string `pactffi_message_reify` returns. Usually it is the JSON
  # object of the message. Two bodies give a string that is not an object: a
  # null body gives `"null"`, and an empty or missing body gives `""`. In both
  # cases pact_ffi drops the metadata, so it is `%{}` here.
  @spec from_json(String.t()) :: t()
  def from_json("null"), do: %__MODULE__{contents: nil, metadata: %{}, content_type: nil}
  def from_json(""), do: %__MODULE__{contents: "", metadata: %{}, content_type: nil}

  def from_json(json) do
    decoded = JSON.decode!(json)
    {contents, content_type} = decode_contents(Map.get(decoded, "contents"))

    %__MODULE__{
      contents: contents,
      metadata: Map.get(decoded, "metadata", %{}),
      content_type: content_type
    }
  end

  @doc false
  # Decodes the `contents` of a reified V4 message, shared by async and sync
  # messages. pact_models writes `%{"content" => c, "contentType" => ct,
  # "encoded" => enc}`, where `enc` is `false` or `"base64"`. The empty body has
  # only `%{"content" => ""}`, and a null body has no envelope at all.
  @spec decode_contents(term()) :: {term(), String.t() | nil}
  def decode_contents(%{"content" => content} = envelope) do
    content_type = Map.get(envelope, "contentType")

    case Map.get(envelope, "encoded") do
      "base64" -> {Base.decode64!(content), content_type}
      _other -> {content, content_type}
    end
  end

  def decode_contents(nil), do: {nil, nil}
  def decode_contents(""), do: {"", nil}
end
