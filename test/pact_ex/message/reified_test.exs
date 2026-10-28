defmodule PactEx.Message.ReifiedTest do
  use ExUnit.Case, async: true

  alias PactEx.Message.Reified

  describe "from_json/1" do
    test "a normal message is decoded with its metadata" do
      json =
        JSON.encode!(%{
          "contents" => %{"content" => "hello", "contentType" => "text/plain", "encoded" => false},
          "metadata" => %{"contentType" => "text/plain", "queue" => "q"}
        })

      assert Reified.from_json(json) == %Reified{
               contents: "hello",
               metadata: %{"contentType" => "text/plain", "queue" => "q"},
               content_type: "text/plain"
             }
    end

    test "a base64 message is decoded to raw bytes" do
      json =
        JSON.encode!(%{
          "contents" => %{
            "content" => Base.encode64(<<1, 2>>),
            "contentType" => "application/x-bin",
            "encoded" => "base64"
          }
        })

      assert %Reified{contents: <<1, 2>>, metadata: %{}, content_type: "application/x-bin"} =
               Reified.from_json(json)
    end

    test "a bare null (null body) has no envelope and no metadata" do
      assert Reified.from_json("null") == %Reified{
               contents: nil,
               metadata: %{},
               content_type: nil
             }
    end

    test "an empty string (empty or missing body) is empty contents without metadata" do
      assert Reified.from_json("") == %Reified{contents: "", metadata: %{}, content_type: nil}
    end
  end

  describe "decode_contents/1" do
    test "a JSON envelope is decoded" do
      envelope = %{
        "content" => %{"a" => 1},
        "contentType" => "application/json",
        "encoded" => false
      }

      assert Reified.decode_contents(envelope) == {%{"a" => 1}, "application/json"}
    end

    test "a base64 envelope is decoded to raw bytes" do
      envelope = %{
        "content" => Base.encode64(<<0, 255, 7>>),
        "contentType" => "application/protobuf",
        "encoded" => "base64"
      }

      assert Reified.decode_contents(envelope) == {<<0, 255, 7>>, "application/protobuf"}
    end

    test "a base64 envelope with a JSON content type is raw bytes too" do
      envelope = %{
        "content" => Base.encode64("{bad"),
        "contentType" => "application/json",
        "encoded" => "base64"
      }

      assert Reified.decode_contents(envelope) == {"{bad", "application/json"}
    end

    test "text content is kept as it is" do
      envelope = %{"content" => "hello", "contentType" => "text/plain", "encoded" => false}
      assert Reified.decode_contents(envelope) == {"hello", "text/plain"}
    end

    test "another encoding keeps the content as it is" do
      envelope = %{"content" => "abc", "contentType" => "text/plain", "encoded" => "other"}
      assert Reified.decode_contents(envelope) == {"abc", "text/plain"}
    end

    test "the empty envelope is an empty string without a content type" do
      assert Reified.decode_contents(%{"content" => ""}) == {"", nil}
    end

    test "a bare null has no envelope" do
      assert Reified.decode_contents(nil) == {nil, nil}
    end

    test "an empty string is an empty body" do
      assert Reified.decode_contents("") == {"", nil}
    end
  end
end
