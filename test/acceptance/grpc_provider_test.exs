defmodule PactEx.Acceptance.GrpcProviderTest do
  use ExUnit.Case, async: false

  alias PactEx.Test.{GrpcInteractions, RouteGuideServer, WrongRouteGuideServer}
  alias PactEx.Verifier

  # Loads plugins. The driver's 60 s startup timeout must fire first; see test_helper.exs.
  @moduletag timeout: 120_000
  @moduletag :plugin
  @moduletag :capture_log
  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    :ok = GrpcInteractions.write_consumer_pact(dir)
    %{dir: dir}
  end

  test "verifies the gRPC pact against an Elixir gRPC server", %{dir: dir} do
    assert :ok = verify_against(RouteGuideServer, dir)
  end

  test "a server that breaks the contract fails verification", %{dir: dir} do
    assert {:error, %PactEx.VerificationError{} = error} =
             verify_against(WrongRouteGuideServer, dir)

    assert Exception.message(error) =~ "Route guide - GetFeature"
  end

  defp verify_against(server, dir) do
    {:ok, _pid, port} = GRPC.Server.start(server, 0, adapter_opts: [ip: {127, 0, 0, 1}])

    try do
      Verifier.verify(
        provider: "grpcprovider",
        provider_url: "http://127.0.0.1:#{port}",
        transports: [%{protocol: "grpc", port: port}],
        dirs: [dir]
      )
    after
      GRPC.Server.stop(server)
    end
  end
end
