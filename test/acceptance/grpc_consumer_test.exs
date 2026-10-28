defmodule PactEx.Acceptance.GrpcConsumerTest do
  use ExUnit.Case, async: false

  alias PactEx.{Plugin, SyncMessage}
  alias Routeguide.RouteGuide.Stub

  # Loads plugins. The driver's 60 s startup timeout must fire first; see test_helper.exs.
  @moduletag timeout: 120_000
  @moduletag :plugin
  @moduletag :capture_log
  @moduletag :tmp_dir
  @proto Path.expand("../fixtures/route_guide.proto", __DIR__)

  setup %{tmp_dir: dir} do
    pact =
      "grpcconsumer"
      |> PactEx.new("grpcprovider", pact_dir: dir)
      |> PactEx.using_plugin("protobuf", "0.8.1")

    %{pact: pact}
  end

  defp get_feature(contents) do
    base = %{
      "pact:proto" => @proto,
      "pact:proto-service" => "RouteGuide/GetFeature",
      "pact:content-type" => "application/protobuf"
    }

    "Route guide - GetFeature"
    |> SyncMessage.new()
    |> SyncMessage.given("feature 'Big Tree' exists")
    |> SyncMessage.with_plugin_contents(
      Plugin.contents("application/protobuf", Map.merge(base, contents))
    )
  end

  defp call(port, point) do
    {:ok, channel} = GRPC.Stub.connect("127.0.0.1:#{port}", adapter: GRPC.Client.Adapters.Mint)

    try do
      Stub.get_feature(channel, point)
    after
      GRPC.Stub.disconnect(channel)
    end
  end

  test "GetFeature success writes a gRPC pact", %{pact: pact, tmp_dir: dir} do
    sm =
      get_feature(%{
        "request" => %{
          "latitude" => "matching(number, 180)",
          "longitude" => "matching(number, 200)"
        },
        "response" => %{
          "name" => "notEmpty('Big Tree')",
          "location" => %{
            "latitude" => "matching(number, 180)",
            "longitude" => "matching(number, 200)"
          }
        }
      })

    assert :ok =
             SyncMessage.run(
               pact,
               sm,
               fn %{transport: %{port: port}} ->
                 assert {:ok, %Routeguide.Feature{name: "Big Tree"}} =
                          call(port, %Routeguide.Point{latitude: 180, longitude: 200})
               end,
               transport: "grpc"
             )

    written = PactFile.read!(dir, {"grpcconsumer", "grpcprovider"})
    assert [%{"name" => "protobuf", "version" => "0.8.1"}] = written["metadata"]["plugins"]

    assert [%{"type" => "Synchronous/Messages", "description" => "Route guide - GetFeature"}] =
             written["interactions"]
  end

  test "NOT_FOUND response metadata reaches the client as a gRPC error", %{pact: pact} do
    sm =
      get_feature(%{
        "request" => %{
          "latitude" => "matching(number, -1)",
          "longitude" => "matching(number, -1)"
        },
        "responseMetadata" => %{
          "grpc-status" => "NOT_FOUND",
          "grpc-message" => "matching(type, 'no feature was found')"
        }
      })

    assert :ok =
             SyncMessage.run(
               pact,
               sm,
               fn %{transport: %{port: port}} ->
                 assert {:error, %GRPC.RPCError{status: 5}} =
                          call(port, %Routeguide.Point{latitude: -1, longitude: -1})
               end,
               transport: "grpc"
             )
  end

  test "a gRPC interaction never called returns MismatchError", %{pact: pact} do
    sm =
      get_feature(%{
        "request" => %{"latitude" => "matching(number, 1)"},
        "response" => %{"name" => "notEmpty('x')"}
      })

    assert {:error,
            %PactEx.MismatchError{mismatches: [%{"path" => path, "error" => error}]} = mismatch} =
             SyncMessage.run(pact, sm, fn _ -> :ok end, transport: "grpc")

    # Confirmed in the plugin source (spike S1).
    assert path =~ "RouteGuide/GetFeature"
    assert error =~ "Did not receive any requests for path"
    assert Exception.message(mismatch) =~ "RouteGuide/GetFeature: Did not receive any requests"
  end

  test "an exception stops the server, cleans plugins and leaves no plugin process", %{
    pact: pact,
    tmp_dir: dir
  } do
    sm =
      get_feature(%{
        "request" => %{"latitude" => "matching(number, 1)"},
        "response" => %{"name" => "notEmpty('x')"}
      })

    assert_raise RuntimeError, fn ->
      SyncMessage.run(
        pact,
        sm,
        fn %{transport: %{port: port}} ->
          send(self(), {:port, port})
          raise "boom"
        end,
        transport: "grpc"
      )
    end

    refute File.exists?(Path.join(dir, "grpcconsumer-grpcprovider.json"))

    # The mock server is gone: it no longer reports a match, and there is
    # nothing left to stop.
    assert_received {:port, port}
    refute PactEx.Native.mock_server_matched(port)
    refute PactEx.Native.cleanup_mock_server(port)

    # Cleanup and the freeing of the pact can finish asynchronously, and the
    # plugin process exits on its own schedule. `gone?/0` polls for up to 5 s.
    assert PluginProcesses.gone?()
  end
end
