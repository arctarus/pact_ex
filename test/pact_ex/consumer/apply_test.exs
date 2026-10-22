defmodule PactEx.Consumer.ApplyTest do
  use ExUnit.Case, async: true

  alias PactEx.{Consumer.Apply, HTTP, Native}
  alias PactEx.HTTP.Interaction

  defp pact_ref, do: Native.new_pact("apply-consumer", "apply-provider")

  defp serve(pact) do
    {:ok, port} = Native.create_mock_server(pact, "127.0.0.1", 0, "http", nil)
    on_exit(fn -> Native.cleanup_mock_server(port) end)
    port
  end

  test "applies a full interaction that a real mock server then serves" do
    pact = pact_ref()

    i =
      HTTP.interaction("applied")
      |> HTTP.given("a state")
      |> HTTP.given("another", %{"k" => "v"})
      |> HTTP.with_request(:post, "/apply",
        query: %{"q" => "1"},
        headers: %{"x-in" => "in"},
        body: %{"a" => 1}
      )
      |> HTTP.will_respond_with(201, headers: %{"x-out" => "out"}, body: "created")

    assert :ok = Apply.interaction(pact, i)
    port = serve(pact)

    resp =
      Req.post!("http://127.0.0.1:#{port}/apply?q=1",
        json: %{a: 1},
        headers: [{"x-in", "in"}],
        decode_body: false
      )

    assert resp.status == 201
    assert resp.body == "created"
    assert Req.Response.get_header(resp, "x-out") == ["out"]
    assert Native.mock_server_matched(port)
  end

  test "an empty list of values makes no calls" do
    pact = pact_ref()

    i =
      HTTP.interaction("empty lists")
      |> HTTP.with_request(:get, "/empty", query: %{"q" => []}, headers: %{"x" => []})
      |> HTTP.will_respond_with(200)

    assert :ok = Apply.interaction(pact, i)
    port = serve(pact)
    assert %{status: 200} = Req.get!("http://127.0.0.1:#{port}/empty")
  end

  test "returns an error naming the interaction when the request is missing" do
    i = HTTP.interaction("lonely") |> HTTP.will_respond_with(200)

    assert {:error, %PactEx.Error{code: -101, message: message}} =
             Apply.interaction(pact_ref(), i)

    assert message =~ "lonely"
    assert message =~ "with_request"
  end

  test "stops at the first native error and returns it as a PactEx.Error" do
    i = HTTP.interaction("nul") |> HTTP.with_request(:get, "/a\0b")

    assert {:error, %PactEx.Error{function: "pactffi_with_request", code: -100}} =
             Apply.interaction(pact_ref(), i)
  end

  test "returns the native error when the pact is already being served" do
    pact = pact_ref()
    first = HTTP.interaction("first") |> HTTP.with_request(:get, "/first")
    assert :ok = Apply.interaction(pact, first)
    _port = serve(pact)

    late = HTTP.interaction("late") |> HTTP.with_request(:get, "/late")

    assert {:error, %PactEx.Error{function: "pactffi_with_request", code: 1}} =
             Apply.interaction(pact, late)
  end

  test "rejects an unsupported response status" do
    i = %Interaction{
      description: "status",
      request: %HTTP.Request{method: "GET", path: "/s"},
      response: %HTTP.Response{status: :ok}
    }

    assert {:error, %PactEx.Error{code: -101, message: message}} =
             Apply.interaction(pact_ref(), i)

    assert message =~ "status"
  end

  test "rejects unsupported value types with a PactEx.Error naming the value" do
    i = %Interaction{
      description: "types",
      request: %HTTP.Request{method: "GET", path: 42}
    }

    assert {:error, %PactEx.Error{code: -101, message: message}} =
             Apply.interaction(pact_ref(), i)

    assert message =~ "path"
    assert message =~ "42"
  end
end
