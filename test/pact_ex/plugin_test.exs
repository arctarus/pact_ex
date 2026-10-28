defmodule PactEx.PluginTest do
  use ExUnit.Case, async: false

  alias PactEx.{Consumer, Consumer.Apply, HTTP, Plugin}

  test "using_plugin/3 accumulates plugins in order" do
    pact =
      "c"
      |> PactEx.new("p")
      |> PactEx.using_plugin("protobuf", "0.8.1")
      |> PactEx.using_plugin("csv")

    assert pact.plugins == [{"protobuf", "0.8.1"}, {"csv", nil}]
  end

  test "using_plugin/3 rejects a plugin that is already in the pact" do
    pact = "c" |> PactEx.new("p") |> PactEx.using_plugin("protobuf", "0.8.1")

    assert_raise ArgumentError, ~r/protobuf/, fn ->
      PactEx.using_plugin(pact, "protobuf", "0.8.1")
    end

    assert_raise ArgumentError, ~r/protobuf/, fn -> PactEx.using_plugin(pact, "protobuf") end
  end

  test "contents/2 builds a PluginContents value" do
    assert %PactEx.PluginContents{content_type: "application/protobuf", contents: %{"a" => 1}} =
             Plugin.contents("application/protobuf", %{"a" => 1})
  end

  test "a missing plugin fails start_mock_server with a clear error" do
    pact = "c" |> PactEx.new("p") |> PactEx.using_plugin("pact-ex-no-such-plugin", "9.9.9")
    i = "x" |> HTTP.interaction() |> HTTP.with_request(:get, "/x") |> HTTP.will_respond_with(200)

    assert {:error, %PactEx.Error{function: "pactffi_using_plugin", code: 2, message: message}} =
             Consumer.start_mock_server(pact, [i])

    assert message =~ "pact-ex-no-such-plugin"
  end

  test "plugin contents next to a different explicit content type are rejected before any native call" do
    body = Plugin.contents("application/protobuf", %{"a" => 1})

    i =
      "x"
      |> HTTP.interaction()
      |> HTTP.with_request(:get, "/x")
      |> HTTP.will_respond_with(200, body: body, content_type: "text/plain")

    assert {:error, %PactEx.Error{function: "PactEx.Consumer.start_mock_server/3", code: -101}} =
             Consumer.start_mock_server(PactEx.new("c", "p"), [i])
  end

  test "validate accepts plugin contents with the same content type" do
    body = Plugin.contents("application/protobuf", %{"a" => 1})

    i =
      "x"
      |> HTTP.interaction()
      |> HTTP.with_request(:get, "/x")
      |> HTTP.will_respond_with(200, body: body, content_type: "application/protobuf")

    assert :ok = Apply.validate(i)
  end

  test "plugin contents in a pact without plugins are rejected before any native call" do
    body = Plugin.contents("application/protobuf", %{"a" => 1})

    i =
      "x"
      |> HTTP.interaction()
      |> HTTP.with_request(:get, "/x")
      |> HTTP.will_respond_with(200, body: body)

    assert {:error,
            %PactEx.Error{
              function: "PactEx.Consumer.start_mock_server/3",
              code: -101,
              message: message
            }} = Consumer.start_mock_server(PactEx.new("c", "p"), [i])

    assert message =~ "an interaction has plugin contents"
    assert message =~ "PactEx.using_plugin"
  end

  test "a plugin that is declared twice is rejected before any native call" do
    # `using_plugin/3` refuses it, so build the pact by hand. A missing plugin would
    # fail with code 2 if the runner got as far as loading it.
    plugins = [{"pact-ex-no-such-plugin", nil}, {"pact-ex-no-such-plugin", "9.9.9"}]
    pact = %{PactEx.new("c", "p") | plugins: plugins}
    i = "x" |> HTTP.interaction() |> HTTP.with_request(:get, "/x") |> HTTP.will_respond_with(200)

    assert {:error,
            %PactEx.Error{
              function: "PactEx.Consumer.start_mock_server/3",
              code: -101,
              message: message
            }} = Consumer.start_mock_server(pact, [i])

    assert message =~ "pact-ex-no-such-plugin"
    assert message =~ "more than once"
  end

  test "plugin contents in a pact that is not V4 are rejected before any native call" do
    body = Plugin.contents("application/protobuf", %{"a" => 1})

    i =
      "x"
      |> HTTP.interaction()
      |> HTTP.with_request(:get, "/x")
      |> HTTP.will_respond_with(200, body: body)

    # A missing plugin would fail with code 2 if the runner got as far as loading it.
    for spec <- [:v2, :v3] do
      pact =
        "c"
        |> PactEx.new("p", spec: spec)
        |> PactEx.using_plugin("pact-ex-no-such-plugin", "9.9.9")

      assert {:error,
              %PactEx.Error{
                function: "PactEx.Consumer.start_mock_server/3",
                code: -101,
                message: message
              }} = Consumer.start_mock_server(pact, [i])

      assert message =~ "V4"
    end
  end
end
