defmodule Routeguide.Point do
  @moduledoc """
  A latitude-longitude point of the route guide proto. Test support only.
  """

  use Protobuf, syntax: :proto3, package: "routeguide", protoc_gen_elixir_version: "0.17.1"

  field(:latitude, 1, type: :int32)
  field(:longitude, 2, type: :int32)
end

defmodule Routeguide.Feature do
  @moduledoc """
  A named feature at a point of the route guide proto. Test support only.
  """

  use Protobuf, syntax: :proto3, package: "routeguide", protoc_gen_elixir_version: "0.17.1"

  field(:name, 1, type: :string)
  field(:location, 2, type: Routeguide.Point)
end

defmodule Routeguide.RouteGuide.Service do
  @moduledoc """
  The `routeguide.RouteGuide` service, with its unary RPC. Test support only.
  """

  use GRPC.Service, name: "routeguide.RouteGuide", protoc_gen_elixir_version: "0.17.1"

  rpc(:GetFeature, Routeguide.Point, Routeguide.Feature)
end

defmodule Routeguide.RouteGuide.Stub do
  @moduledoc """
  The gRPC client of `Routeguide.RouteGuide.Service`. Test support only.
  """

  use GRPC.Stub, service: Routeguide.RouteGuide.Service
end
