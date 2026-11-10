defmodule PactEx.Test.GrpcInteractions do
  @moduledoc """
  The gRPC route guide interactions, shared by the consumer and the provider
  acceptance tests. Test support only.
  """

  alias PactEx.{Plugin, SyncMessage}
  alias Routeguide.RouteGuide.Stub

  @proto Path.expand("../../fixtures/route_guide.proto", __DIR__)
  @description "Route guide - GetFeature"
  @not_found_description "Route guide - GetFeature not found"

  @doc "The pact of the route guide, with the protobuf plugin."
  @spec pact(Path.t()) :: PactEx.Pact.t()
  def pact(dir) do
    "grpcconsumer"
    |> PactEx.new("grpcprovider", pact_dir: dir)
    |> PactEx.using_plugin("protobuf", "0.8.1")
  end

  @doc """
  A `GetFeature` sync message. `contents` has the `"request"` and `"response"`
  (or `"responseMetadata"`) of the plugin.
  """
  @spec get_feature(map(), String.t()) :: SyncMessage.t()
  def get_feature(contents, description \\ @description) do
    base = %{
      "pact:proto" => @proto,
      "pact:proto-service" => "RouteGuide/GetFeature",
      "pact:content-type" => "application/protobuf"
    }

    description
    |> SyncMessage.new()
    |> SyncMessage.given("feature 'Big Tree' exists")
    |> SyncMessage.with_plugin_contents(
      Plugin.contents("application/protobuf", Map.merge(base, contents))
    )
  end

  @doc "Calls `GetFeature` on the server at `port`."
  @spec call(pos_integer(), Routeguide.Point.t()) ::
          {:ok, Routeguide.Feature.t()} | {:error, Exception.t()}
  def call(port, point) do
    {:ok, channel} = GRPC.Stub.connect("127.0.0.1:#{port}", adapter: GRPC.Client.Adapters.Mint)

    try do
      Stub.get_feature(channel, point)
    after
      GRPC.Stub.disconnect(channel)
    end
  end

  @doc """
  Writes the consumer pact into `dir`: a call that finds a feature and one that
  does not (`NOT_FOUND`), each through a real gRPC client and the mock server of
  the plugin.
  """
  @spec write_consumer_pact(Path.t()) :: :ok
  def write_consumer_pact(dir) do
    found =
      get_feature(%{
        "request" => point("matching(number, 180)", "matching(number, 200)"),
        "response" => %{
          "name" => "notEmpty('Big Tree')",
          "location" => point("matching(number, 180)", "matching(number, 200)")
        }
      })

    not_found =
      get_feature(
        %{
          "request" => point("matching(number, -1)", "matching(number, -1)"),
          "responseMetadata" => %{
            "grpc-status" => "NOT_FOUND",
            "grpc-message" => "matching(type, 'no feature was found')"
          }
        },
        @not_found_description
      )

    run(dir, found, %Routeguide.Point{latitude: 180, longitude: 200})
    run(dir, not_found, %Routeguide.Point{latitude: -1, longitude: -1})
  end

  defp point(latitude, longitude), do: %{"latitude" => latitude, "longitude" => longitude}

  defp run(dir, message, point) do
    SyncMessage.run!(
      pact(dir),
      message,
      fn %{transport: %{port: port}} -> call(port, point) end,
      transport: "grpc"
    )
  end
end
