defmodule PactEx.Native.MessagesTest do
  use ExUnit.Case, async: true
  alias PactEx.Native

  defp v4_pact do
    pact = Native.new_pact("native-msg-consumer", "native-msg-provider")
    :ok = Native.with_specification(pact, :v4)
    pact
  end

  test "async message reifies matchers to their examples and sets metadata" do
    pact = v4_pact()
    i = Native.new_message_interaction(pact, "a weather message")
    :ok = Native.given(i, "weather available")

    :ok =
      Native.with_body(
        i,
        :request,
        "application/json",
        ~s({"temp": {"pact:matcher:type": "type", "value": 23.0}})
      )

    :ok = Native.with_metadata(i, "queue", JSON.encode!("weather"), :request)

    assert {:ok, json} = Native.message_reify(i)
    reified = JSON.decode!(json)
    assert reified["contents"]["content"] == %{"temp" => 23.0}
    assert reified["metadata"]["queue"] == "weather"
  end

  test "sync message generates request and response contents" do
    pact = v4_pact()
    i = Native.new_sync_message_interaction(pact, "a sync message")
    :ok = Native.with_body(i, :request, "application/json", ~s({"id": 1}))
    :ok = Native.with_body(i, :response, "application/json", ~s({"name": "Ann"}))

    assert {:ok, json} = Native.sync_message_generate_contents(i)
    generated = JSON.decode!(json)
    assert generated["request"]["contents"]["content"] == %{"id" => 1}
    assert [%{"contents" => %{"content" => %{"name" => "Ann"}}}] = generated["response"]
  end

  @tag :tmp_dir
  test "message pacts are written by pact handle", %{tmp_dir: dir} do
    pact = v4_pact()
    i = Native.new_message_interaction(pact, "written message")
    :ok = Native.with_body(i, :request, "application/json", ~s({"a": 1}))
    assert Native.pact_handle_write_file(pact, dir, false) == :ok

    written =
      dir
      |> Path.join("native-msg-consumer-native-msg-provider.json")
      |> File.read!()
      |> JSON.decode!()

    assert [%{"type" => "Asynchronous/Messages"}] = written["interactions"]
  end

  test "message_reify on a sync message interaction returns an error" do
    i = Native.new_sync_message_interaction(v4_pact(), "a sync message")

    assert {:error, %{function: "pactffi_message_reify", code: 1}} = Native.message_reify(i)
  end

  test "sync_message_generate_contents on an async message interaction returns an error" do
    i = Native.new_message_interaction(v4_pact(), "an async message")

    assert {:error, %{function: "pactffi_sync_message_generate_contents", code: 1}} =
             Native.sync_message_generate_contents(i)
  end

  test "with_metadata on an HTTP interaction returns an error" do
    i = Native.new_interaction(v4_pact(), "an http interaction")

    assert {:error, %{function: "pactffi_with_metadata", code: 1}} =
             Native.with_metadata(i, "queue", JSON.encode!("weather"), :request)
  end

  test "with_metadata rejects a NUL byte in the key" do
    i = Native.new_message_interaction(v4_pact(), "a message")

    assert {:error, %{function: "pactffi_with_metadata", code: -100}} =
             Native.with_metadata(i, "a\0b", "1", :request)
  end

  test "with_metadata raises ArgumentError for an unknown part" do
    i = Native.new_message_interaction(v4_pact(), "a message")

    assert_raise ArgumentError, fn -> Native.with_metadata(i, "queue", "1", :bogus) end
  end

  test "interaction_contents raises ArgumentError for an unknown part" do
    i = Native.new_message_interaction(v4_pact(), "a message")

    assert_raise ArgumentError, fn ->
      Native.interaction_contents(i, :bogus, "application/json", "{}")
    end
  end

  test "pact_handle_write_file rejects a NUL byte in the directory" do
    assert {:error, %{function: "pactffi_pact_handle_write_file", code: -100}} =
             Native.pact_handle_write_file(v4_pact(), "a\0b", false)
  end

  test "interaction_contents returns an error for an invalid content type" do
    i = Native.new_message_interaction(v4_pact(), "a message")

    assert {:error, %{function: "pactffi_interaction_contents", message: message}} =
             Native.interaction_contents(i, :request, "not a content type", "{}")

    assert message =~ "not a content type"
  end
end
