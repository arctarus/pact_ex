defmodule PactEx.Acceptance.GrpcConsumerTest do
  use ExUnit.Case, async: false

  alias PactEx.SyncMessage
  alias PactEx.Test.GrpcInteractions

  # Loads plugins. The driver's 60 s startup timeout must fire first; see test_helper.exs.
  @moduletag timeout: 120_000
  @moduletag :plugin
  @moduletag :capture_log
  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    %{pact: GrpcInteractions.pact(dir)}
  end

  test "GetFeature success writes a gRPC pact", %{pact: pact, tmp_dir: dir} do
    sm =
      GrpcInteractions.get_feature(%{
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
                          GrpcInteractions.call(port, %Routeguide.Point{
                            latitude: 180,
                            longitude: 200
                          })
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
      GrpcInteractions.get_feature(%{
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
                          GrpcInteractions.call(port, %Routeguide.Point{
                            latitude: -1,
                            longitude: -1
                          })
               end,
               transport: "grpc"
             )
  end

  test "a gRPC interaction never called returns MismatchError", %{pact: pact} do
    sm =
      GrpcInteractions.get_feature(%{
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
      GrpcInteractions.get_feature(%{
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
