defmodule PactEx.Test.RouteGuideServer do
  @moduledoc """
  A route guide gRPC server that keeps the contract: it knows one feature, and
  answers `NOT_FOUND` for any other point. Test support only.
  """

  use GRPC.Server, service: Routeguide.RouteGuide.Service

  @spec get_feature(Routeguide.Point.t(), term()) :: Routeguide.Feature.t()
  def get_feature(%Routeguide.Point{latitude: 180, longitude: 200} = point, _stream),
    do: %Routeguide.Feature{name: "Big Tree", location: point}

  def get_feature(_point, _stream),
    do: raise(GRPC.RPCError, status: :not_found, message: "no feature was found")
end

defmodule PactEx.Test.WrongRouteGuideServer do
  @moduledoc """
  A route guide gRPC server that breaks the contract: the feature it knows has
  an empty name. Test support only.
  """

  use GRPC.Server, service: Routeguide.RouteGuide.Service

  @spec get_feature(Routeguide.Point.t(), term()) :: Routeguide.Feature.t()
  def get_feature(%Routeguide.Point{latitude: 180, longitude: 200} = point, _stream),
    do: %Routeguide.Feature{name: "", location: point}

  def get_feature(_point, _stream),
    do: raise(GRPC.RPCError, status: :not_found, message: "no feature was found")
end
