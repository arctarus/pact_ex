defmodule PactEx.SyncMessage.GeneratedTest do
  use ExUnit.Case, async: true
  alias PactEx.SyncMessage.Generated

  defp envelope(content),
    do: %{"contents" => %{"content" => content, "contentType" => "application/json"}}

  test "from_json/1 decodes the request and every response" do
    json =
      JSON.encode!(%{
        "request" => envelope(%{"id" => 1}),
        "response" => [envelope(%{"name" => "Ann"}), envelope(%{"name" => "Bob"})]
      })

    assert %Generated{
             request: %{"id" => 1},
             responses: [%{"name" => "Ann"}, %{"name" => "Bob"}],
             transport: nil
           } = Generated.from_json(json)
  end

  test "from_json/1 decodes base64 contents to raw bytes" do
    contents = %{
      "contents" => %{
        "content" => Base.encode64(<<0, 255>>),
        "contentType" => "application/protobuf",
        "encoded" => "base64"
      }
    }

    json = JSON.encode!(%{"request" => contents, "response" => [contents]})
    assert %Generated{request: <<0, 255>>, responses: [<<0, 255>>]} = Generated.from_json(json)
  end

  test "from_json/1 tolerates missing, null and empty contents" do
    json =
      JSON.encode!(%{
        "request" => %{},
        "response" => [
          %{},
          %{"contents" => nil},
          %{"contents" => %{}},
          %{"contents" => %{"content" => ""}}
        ]
      })

    assert %Generated{request: nil, responses: [nil, nil, nil, ""]} = Generated.from_json(json)
  end

  test "from_json/1 tolerates a missing request and missing or null responses" do
    assert %Generated{request: nil, responses: []} = Generated.from_json("{}")

    assert %Generated{request: nil, responses: []} =
             Generated.from_json(~s({"request": null, "response": null}))
  end
end
