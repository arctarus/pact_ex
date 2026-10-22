defmodule PactEx.HTTPTest do
  use ExUnit.Case, async: true

  alias PactEx.HTTP

  describe "PactEx.new/3" do
    test "applies defaults" do
      assert %PactEx.Pact{consumer: "c", provider: "p", spec: :v4, pact_dir: "pacts"} =
               PactEx.new("c", "p")
    end

    test "accepts spec and pact_dir" do
      assert %PactEx.Pact{spec: :v3, pact_dir: "tmp/pacts"} =
               PactEx.new("c", "p", spec: :v3, pact_dir: "tmp/pacts")
    end

    test "accepts every supported spec" do
      for spec <- [:v2, :v3, :v4] do
        assert %PactEx.Pact{spec: ^spec} = PactEx.new("c", "p", spec: spec)
      end
    end

    test "rejects an invalid spec" do
      assert_raise ArgumentError, ~r/spec/, fn -> PactEx.new("c", "p", spec: :v5) end
      assert_raise ArgumentError, ~r/spec/, fn -> PactEx.new("c", "p", spec: "v4") end
    end

    test "rejects unknown options" do
      assert_raise ArgumentError, fn -> PactEx.new("c", "p", pactdir: "x") end
    end

    test "delegates to PactEx.Pact.new/3" do
      assert PactEx.new("c", "p", spec: :v2) == PactEx.Pact.new("c", "p", spec: :v2)
    end
  end

  describe "enforced keys" do
    test "Pact requires consumer and provider" do
      assert_raise ArgumentError, ~r/consumer/, fn -> struct!(PactEx.Pact, provider: "p") end
      assert_raise ArgumentError, ~r/provider/, fn -> struct!(PactEx.Pact, consumer: "c") end
    end

    test "Interaction requires description" do
      assert_raise ArgumentError, ~r/description/, fn -> struct!(HTTP.Interaction, []) end
    end

    test "Request requires method and path" do
      assert_raise ArgumentError, ~r/method/, fn -> struct!(HTTP.Request, path: "/") end
      assert_raise ArgumentError, ~r/path/, fn -> struct!(HTTP.Request, method: "GET") end
    end

    test "Response requires status" do
      assert_raise ArgumentError, ~r/status/, fn -> struct!(HTTP.Response, []) end
    end
  end

  describe "interaction/1" do
    test "starts with only a description" do
      assert %HTTP.Interaction{
               description: "get user",
               provider_states: [],
               request: nil,
               response: nil
             } = HTTP.interaction("get user")
    end
  end

  describe "given/3" do
    test "given/2 stores nil params" do
      i = HTTP.interaction("x") |> HTTP.given("is admin")
      assert i.provider_states == [{"is admin", nil}]
    end

    test "given/3 stores the params map" do
      i = HTTP.interaction("x") |> HTTP.given("user exists", %{"id" => 1})
      assert i.provider_states == [{"user exists", %{"id" => 1}}]
    end

    test "appends in call order" do
      i =
        HTTP.interaction("x")
        |> HTTP.given("a")
        |> HTTP.given("b", %{"k" => "v"})
        |> HTTP.given("c")

      assert i.provider_states == [{"a", nil}, {"b", %{"k" => "v"}}, {"c", nil}]
    end
  end

  describe "with_request/4" do
    test "applies defaults" do
      i = HTTP.interaction("x") |> HTTP.with_request(:get, "/users")

      assert i.request == %HTTP.Request{
               method: "GET",
               path: "/users",
               query: %{},
               headers: %{},
               body: nil,
               content_type: nil
             }
    end

    test "stores every option" do
      i =
        HTTP.interaction("x")
        |> HTTP.with_request(:post, "/users",
          query: %{"full" => "true"},
          headers: %{"accept" => "application/json"},
          body: %{"name" => "Ann"},
          content_type: "application/json"
        )

      assert %HTTP.Request{
               method: "POST",
               path: "/users",
               query: %{"full" => "true"},
               headers: %{"accept" => "application/json"},
               body: %{"name" => "Ann"},
               content_type: "application/json"
             } = i.request
    end

    test "accepts a string method" do
      i = HTTP.interaction("x") |> HTTP.with_request("DELETE", "/users/1")
      assert i.request.method == "DELETE"
    end

    test "upper-cases lowercase string methods" do
      i = HTTP.interaction("x") |> HTTP.with_request("patch", "/users/1")
      assert i.request.method == "PATCH"
    end

    test "upper-cases atom methods" do
      for {atom, string} <- [get: "GET", put: "PUT", options: "OPTIONS"] do
        i = HTTP.interaction("x") |> HTTP.with_request(atom, "/")
        assert i.request.method == string
      end
    end

    test "accepts a matcher map as path" do
      path = %{"pact:matcher:type" => "regex", "regex" => "/users/\\d+", "value" => "/users/1"}
      i = HTTP.interaction("x") |> HTTP.with_request(:get, path)
      assert i.request.path == path
    end

    test "keeps the rest of the interaction untouched" do
      i =
        HTTP.interaction("x")
        |> HTTP.given("s")
        |> HTTP.with_request(:get, "/")

      assert i.description == "x"
      assert i.provider_states == [{"s", nil}]
      assert i.response == nil
    end

    test "rejects unknown options" do
      assert_raise ArgumentError, fn ->
        HTTP.interaction("x") |> HTTP.with_request(:get, "/", params: %{})
      end
    end
  end

  describe "will_respond_with/3" do
    test "applies defaults" do
      i = HTTP.interaction("x") |> HTTP.will_respond_with(204)

      assert i.response == %HTTP.Response{
               status: 204,
               headers: %{},
               body: nil,
               content_type: nil
             }
    end

    test "stores headers, body and content_type" do
      i =
        HTTP.interaction("x")
        |> HTTP.will_respond_with(200,
          headers: %{"x-id" => "1"},
          body: %{"id" => 1},
          content_type: "application/json"
        )

      assert %HTTP.Response{
               status: 200,
               headers: %{"x-id" => "1"},
               body: %{"id" => 1},
               content_type: "application/json"
             } = i.response
    end

    test "rejects unknown options" do
      assert_raise ArgumentError, fn ->
        HTTP.interaction("x") |> HTTP.will_respond_with(200, status: 201)
      end
    end
  end

  test "builder keeps provider states in order and normalises the method" do
    i =
      HTTP.interaction("get user")
      |> HTTP.given("user exists", %{"id" => 1})
      |> HTTP.given("is admin")
      |> HTTP.with_request(:get, "/users/1",
        query: %{"full" => "true"},
        headers: %{"accept" => "application/json"}
      )
      |> HTTP.will_respond_with(200, body: %{"id" => 1})

    assert i.provider_states == [{"user exists", %{"id" => 1}}, {"is admin", nil}]
    assert %HTTP.Request{method: "GET", path: "/users/1", query: %{"full" => "true"}} = i.request
    assert %HTTP.Response{status: 200, body: %{"id" => 1}} = i.response
  end
end
