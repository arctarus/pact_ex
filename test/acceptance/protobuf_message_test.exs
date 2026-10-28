defmodule PactEx.Acceptance.ProtobufMessageTest do
  use ExUnit.Case, async: false

  alias PactEx.{Message, Plugin}

  @moduletag :plugin
  @moduletag :capture_log
  @moduletag :tmp_dir

  test "protobuf message contents arrive as raw bytes", %{tmp_dir: dir} do
    proto = Path.expand("../fixtures/route_guide.proto", __DIR__)

    pact =
      "protobuf-msg-consumer"
      |> PactEx.new("protobuf-msg-provider", pact_dir: dir)
      |> PactEx.using_plugin("protobuf", "0.8.1")

    msg =
      "feature message"
      |> Message.new()
      |> Message.with_contents(
        Plugin.contents("application/protobuf", %{
          "pact:proto" => proto,
          "pact:message-type" => "Feature",
          "pact:content-type" => "application/protobuf",
          "name" => "notEmpty('Big Tree')"
        })
      )

    assert :ok =
             Message.run(pact, msg, fn %Message.Reified{contents: bytes} ->
               assert is_binary(bytes)
               assert %Routeguide.Feature{name: "Big Tree"} = Routeguide.Feature.decode(bytes)
             end)

    written = PactFile.read!(dir, {"protobuf-msg-consumer", "protobuf-msg-provider"})

    assert %{"interactions" => [interaction], "metadata" => %{"plugins" => plugins}} = written
    assert %{"type" => "Asynchronous/Messages", "description" => "feature message"} = interaction
    assert %{"contents" => %{"contentType" => "application/protobuf" <> _}} = interaction
    assert [%{"name" => "protobuf", "version" => "0.8.1"}] = plugins

    # Nothing may be left running once `run/4` returns.
    assert PluginProcesses.gone?()
  end

  # The plugin returns zero bytes for a message with only default fields.
  # pact-plugin-driver turns that into an empty body, which pact_ffi reifies to "".
  test "a protobuf message with no fields set arrives as an empty binary", %{tmp_dir: dir} do
    proto = Path.expand("../fixtures/route_guide.proto", __DIR__)

    pact =
      "protobuf-empty-consumer"
      |> PactEx.new("protobuf-empty-provider", pact_dir: dir)
      |> PactEx.using_plugin("protobuf", "0.8.1")

    msg =
      "empty feature message"
      |> Message.new()
      |> Message.with_contents(
        Plugin.contents("application/protobuf", %{
          "pact:proto" => proto,
          "pact:message-type" => "Feature",
          "pact:content-type" => "application/protobuf"
        })
      )

    assert :ok =
             Message.run(pact, msg, fn %Message.Reified{} = reified ->
               assert reified.contents == ""
               assert reified.metadata == %{}
             end)

    written = PactFile.read!(dir, {"protobuf-empty-consumer", "protobuf-empty-provider"})
    assert %{"interactions" => [%{"description" => "empty feature message"}]} = written

    assert PluginProcesses.gone?()
  end
end
