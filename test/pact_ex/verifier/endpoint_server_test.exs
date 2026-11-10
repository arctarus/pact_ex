defmodule PactEx.Verifier.EndpointServerTest do
  use ExUnit.Case, async: true

  alias PactEx.Verifier.EndpointServer

  test "serves the endpoint on a free port of 127.0.0.1 until it is stopped" do
    handler = fn "a state", %{"a" => 1}, :setup -> {:ok, %{"id" => 1}} end
    {:ok, %{port: port} = server} = EndpointServer.start(%{state_handler: handler})

    assert port > 0
    url = "http://127.0.0.1:#{port}/_pact/state"
    body = %{"state" => "a state", "params" => %{"a" => 1}, "action" => "setup"}

    assert %{status: 200, body: %{"id" => 1}} = Req.post!(url, json: body, retry: false)

    assert :ok = EndpointServer.stop(server)
    # A request to a stopped listener is refused, or the connection closes
    # first, depending on timing.
    assert {:error, %{reason: reason}} = Req.post(url, json: body, retry: false)
    assert reason in [:econnrefused, :closed]
  end

  test "two servers get different ports" do
    {:ok, a} = EndpointServer.start(%{})
    {:ok, b} = EndpointServer.start(%{})
    assert a.port != b.port
    EndpointServer.stop(a)
    EndpointServer.stop(b)
  end
end
