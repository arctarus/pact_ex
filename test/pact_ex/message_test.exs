defmodule PactEx.MessageTest do
  use ExUnit.Case, async: true
  import PactEx.Matchers
  alias PactEx.Message

  # Loads plugins. The driver's 60 s startup timeout must fire first; see test_helper.exs.
  @moduletag timeout: 120_000
  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    %{pact: PactEx.new("msg-consumer", "msg-provider", pact_dir: dir)}
  end

  defp read_pact(dir), do: PactFile.read!(dir, {"msg-consumer", "msg-provider"})

  test "JSON message with matchers and metadata is reified and written", %{
    pact: pact,
    tmp_dir: dir
  } do
    msg =
      Message.new("a weather data message")
      |> Message.given("weather data for animals", %{"weather" => "cold"})
      |> Message.with_contents(%{
        "temperature" => like(23.0),
        "timestamp" => "2024-03-14T10:22:13+05:30"
      })
      |> Message.with_metadata(%{"queue" => regex("weather.eu", "^weather\\.[a-z]+$")})

    assert :ok =
             Message.run(pact, msg, fn %Message.Reified{contents: contents, metadata: metadata} ->
               assert contents == %{
                        "temperature" => 23.0,
                        "timestamp" => "2024-03-14T10:22:13+05:30"
                      }

               assert metadata["queue"] == "weather.eu"
             end)

    [written] = read_pact(dir)["interactions"]
    assert written["type"] == "Asynchronous/Messages"
    assert written["matchingRules"]["metadata"]["queue"]

    assert [%{"name" => "weather data for animals", "params" => %{"weather" => "cold"}}] =
             written["providerStates"]
  end

  test "string metadata keeps its type", %{pact: pact} do
    msg =
      Message.new("metadata types")
      |> Message.with_contents(%{"a" => 1})
      |> Message.with_metadata(%{"partition" => "5", "flag" => "true"})

    assert :ok =
             Message.run(pact, msg, fn %Message.Reified{metadata: metadata} ->
               assert metadata["partition"] == "5"
               assert metadata["flag"] == "true"
             end)
  end

  test "a pact file that cannot be written is an error that names the directory", %{
    tmp_dir: dir
  } do
    blocker = Path.join(dir, "blocker")
    File.write!(blocker, "x")
    pact = PactEx.new("msg-consumer", "msg-provider", pact_dir: blocker)
    msg = Message.new("unwritable") |> Message.with_contents(%{"a" => 1})

    assert {:error,
            %PactEx.Error{function: "pactffi_pact_handle_write_file", code: 2, message: message}} =
             Message.run(pact, msg, fn _reified -> :ok end)

    assert message =~ "could not write the pact file to #{blocker}"
  end

  test "a pact that is not V4 is rejected", %{tmp_dir: dir} do
    pact = PactEx.new("msg-consumer", "msg-provider", pact_dir: dir, spec: :v3)
    msg = Message.new("v3") |> Message.with_contents(%{"a" => 1})

    assert {:error, %PactEx.Error{function: "PactEx.Message.run/4", code: -101, message: message}} =
             Message.run(pact, msg, fn _ -> flunk("the handler must not run") end)

    assert message =~ "V4"
    refute File.exists?(Path.join(dir, "msg-consumer-msg-provider.json"))
  end

  test "a message without contents is rejected before any native call", %{pact: pact} do
    # A missing plugin would fail with code 2 if the runner got as far as loading it.
    pact = PactEx.using_plugin(pact, "pact-ex-no-such-plugin", "9.9.9")

    for msg <- [
          Message.new("no contents"),
          Message.new("empty string") |> Message.with_contents("")
        ] do
      assert {:error, %PactEx.Error{function: "PactEx.Message.run/4", code: -101}} =
               Message.run(pact, msg, fn _ -> flunk("the handler must not run") end)
    end
  end

  test "a plugin that is declared twice is rejected before any native call", %{pact: pact} do
    # A missing plugin would fail with code 2 if the runner got as far as loading it.
    pact = %{pact | plugins: [{"pact-ex-no-such-plugin", nil}, {"pact-ex-no-such-plugin", nil}]}
    msg = Message.new("twice") |> Message.with_contents(%{"a" => 1})

    assert {:error, %PactEx.Error{function: "PactEx.Message.run/4", code: -101, message: message}} =
             Message.run(pact, msg, fn _ -> flunk("the handler must not run") end)

    assert message =~ "more than once"
  end

  test "plugin contents in a pact without plugins are rejected before any native call", %{
    pact: pact
  } do
    msg =
      Message.new("plugin")
      |> Message.with_contents(PactEx.Plugin.contents("application/protobuf", %{"a" => 1}))

    assert {:error, %PactEx.Error{function: "PactEx.Message.run/4", code: -101, message: message}} =
             Message.run(pact, msg, fn _ -> flunk("the handler must not run") end)

    assert message =~ "the message has plugin contents"
    assert message =~ "PactEx.using_plugin"
  end

  test "a content type that names another media type than the plugin contents is rejected", %{
    pact: pact
  } do
    # A missing plugin would fail with code 2 if the runner got as far as loading it.
    pact = PactEx.using_plugin(pact, "pact-ex-no-such-plugin", "9.9.9")
    contents = PactEx.Plugin.contents("application/protobuf", %{"a" => 1})

    assert {:error, %PactEx.Error{function: "PactEx.Message.run/4", code: -101, message: message}} =
             Message.new("conflict")
             |> Message.with_contents(contents, content_type: "application/json")
             |> then(&Message.run(pact, &1, fn _ -> flunk("the handler must not run") end))

    assert message =~ "application/protobuf"

    # The same media type with another case and a parameter is not a conflict: it gets past
    # the checks and fails on the missing plugin, with code 2.
    assert {:error, %PactEx.Error{function: "pactffi_using_plugin", code: 2}} =
             Message.new("same type")
             |> Message.with_contents(contents,
               content_type: "Application/Protobuf; charset=utf-8"
             )
             |> then(&Message.run(pact, &1, fn _ -> flunk("the handler must not run") end))
  end

  test "metadata and provider state params that cannot be encoded are rejected before any native call",
       %{pact: pact} do
    # A missing plugin would fail with code 2 if the runner got as far as loading it.
    pact = PactEx.using_plugin(pact, "pact-ex-no-such-plugin", "9.9.9")
    msg = Message.new("bad json") |> Message.with_contents(%{"a" => 1})

    for msg <- [
          Message.with_metadata(msg, %{"key" => {1, 2}}),
          Message.with_metadata(msg, %{"key" => %{:a => 1, "a" => 2}}),
          Message.given(msg, "a state", %{:a => 1, "a" => 2})
        ] do
      assert {:error, %PactEx.Error{function: "PactEx.Message.run/4", code: -101}} =
               Message.run(pact, msg, fn _ -> flunk("the handler must not run") end)
    end
  end

  test "contents that cannot be encoded are rejected before any native call", %{pact: pact} do
    pact = PactEx.using_plugin(pact, "pact-ex-no-such-plugin", "9.9.9")
    msg = Message.new("bad contents") |> Message.with_contents(%{"a" => {1, 2}})

    assert {:error, %PactEx.Error{function: "PactEx.Message.run/4", code: -101}} =
             Message.run(pact, msg, fn _ -> flunk("the handler must not run") end)
  end

  # `with_body` never makes a Null body, so this goes through the normal
  # envelope path: the content is the JSON text `null`.
  test "JSON null contents reify to nil", %{pact: pact} do
    msg =
      Message.new("null body") |> Message.with_contents("null", content_type: "application/json")

    assert :ok =
             Message.run(pact, msg, fn %Message.Reified{contents: contents} ->
               assert contents == nil
             end)
  end

  test "an exception in the handler writes nothing and re-raises", %{pact: pact, tmp_dir: dir} do
    msg = Message.new("boom") |> Message.with_contents(%{"a" => 1})
    assert_raise RuntimeError, "boom", fn -> Message.run(pact, msg, fn _ -> raise "boom" end) end
    refute File.exists?(Path.join(dir, "msg-consumer-msg-provider.json"))
  end

  test "a JSON content type with text that is not JSON arrives as raw bytes", %{pact: pact} do
    msg =
      Message.new("bad json") |> Message.with_contents("{bad", content_type: "application/json")

    assert :ok =
             Message.run(pact, msg, fn r ->
               assert r.contents == "{bad"
               assert r.content_type =~ "application/json"
             end)
  end

  test "plain text contents keep their content type", %{pact: pact} do
    msg = Message.new("text") |> Message.with_contents("hello", content_type: "text/plain")

    assert :ok =
             Message.run(pact, msg, fn r ->
               assert r.contents == "hello"
               assert r.content_type =~ "text/plain"
             end)
  end

  test "binary contents arrive as raw bytes", %{pact: pact} do
    bytes = <<0, 255, 1, 2>>
    msg = Message.new("binary") |> Message.with_contents(bytes)

    assert :ok =
             Message.run(pact, msg, fn r ->
               assert r.contents == bytes
               assert r.content_type =~ "application/octet-stream"
             end)
  end

  test "run!/4 returns :ok and raises the error", %{pact: pact} do
    ok = Message.new("ok") |> Message.with_contents(%{"a" => 1})
    assert :ok = Message.run!(pact, ok, fn _ -> :ignored end)

    assert_raise PactEx.Error, ~r/contents/, fn ->
      Message.run!(pact, Message.new("none"), fn _ -> :ignored end)
    end
  end

  test "run/4 takes no options", %{pact: pact} do
    msg = Message.new("opts") |> Message.with_contents(%{"a" => 1})
    assert_raise ArgumentError, fn -> Message.run(pact, msg, fn _ -> :ok end, foo: 1) end
  end

  describe "builders" do
    test "new/1, given/3, with_contents/3 and with_metadata/2" do
      msg =
        Message.new("m")
        |> Message.given("a")
        |> Message.given("b", %{"x" => 1})
        |> Message.with_contents(%{"k" => 1}, content_type: "application/json")
        |> Message.with_metadata(%{"a" => 1})
        |> Message.with_metadata(%{"b" => 2})

      assert msg == %Message{
               description: "m",
               provider_states: [{"a", nil}, {"b", %{"x" => 1}}],
               contents: %{"k" => 1},
               content_type: "application/json",
               metadata: %{"a" => 1, "b" => 2}
             }
    end

    test "with_contents/3 rejects unknown options" do
      assert_raise ArgumentError, fn -> Message.with_contents(Message.new("m"), %{}, foo: 1) end
    end
  end
end
