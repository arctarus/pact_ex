defmodule PactEx.Acceptance.ProtobufHttpTest do
  use ExUnit.Case, async: false

  alias PactEx.{Consumer, HTTP, Plugin}

  @moduletag :plugin
  @moduletag :tmp_dir

  test "HTTP response with a protobuf body via the plugin", %{tmp_dir: dir} do
    proto = Path.expand("../fixtures/route_guide.proto", __DIR__)

    pact =
      "plugin-http-consumer"
      |> PactEx.new("plugin-http-provider", pact_dir: dir)
      |> PactEx.using_plugin("protobuf", "0.8.1")

    body =
      Plugin.contents("application/protobuf", %{
        "pact:proto" => proto,
        "pact:message-type" => "Feature",
        "pact:content-type" => "application/protobuf",
        "name" => "notEmpty('Big Tree')"
      })

    i =
      "get feature"
      |> HTTP.interaction()
      |> HTTP.with_request(:get, "/feature")
      |> HTTP.will_respond_with(200, body: body)

    assert :ok =
             Consumer.run(pact, [i], fn m ->
               resp = Req.get!(m.url <> "/feature", decode_body: false)
               assert %Routeguide.Feature{name: "Big Tree"} = Routeguide.Feature.decode(resp.body)
             end)
  end

  test "a second plugin that fails to load cleans up the first one", %{tmp_dir: dir} do
    pact =
      "plugin-http-consumer"
      |> PactEx.new("plugin-http-provider", pact_dir: dir)
      |> PactEx.using_plugin("protobuf", "0.8.1")
      |> PactEx.using_plugin("pact-ex-no-such-plugin", "9.9.9")

    i =
      "x"
      |> HTTP.interaction()
      |> HTTP.with_request(:get, "/x")
      |> HTTP.will_respond_with(200)

    assert {:error, %PactEx.Error{function: "pactffi_using_plugin", code: 2}} =
             Consumer.start_mock_server(pact, [i])

    # Without the explicit cleanup the protobuf plugin would run until the
    # test process happens to garbage-collect the pact. `gone?/0` polls for up to 5 s.
    assert PluginProcesses.gone?()
  end
end
