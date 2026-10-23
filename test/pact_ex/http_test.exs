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

    test "rejects a :pact_dir that is not a non-empty string" do
      for dir <- ["", nil, :pacts, 1, ["pacts"]] do
        assert_raise ArgumentError, ~r/pact_dir/, fn -> PactEx.new("c", "p", pact_dir: dir) end
      end
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

  describe "argument validation" do
    # Hides the value from the compile-time type checker, which would
    # otherwise warn about the deliberately invalid calls below.
    defp bad(value), do: Function.identity(value)

    test "PactEx.new/3 rejects a non-binary consumer or provider" do
      assert_raise FunctionClauseError, fn -> PactEx.new(bad(:c), "p") end
      assert_raise FunctionClauseError, fn -> PactEx.new("c", bad(1)) end
    end

    test "interaction/1 rejects a non-binary description" do
      assert_raise FunctionClauseError, fn -> HTTP.interaction(bad(:x)) end
    end

    test "given/3 rejects a non-binary state" do
      assert_raise FunctionClauseError, fn -> HTTP.interaction("x") |> HTTP.given(bad(:s)) end
    end

    test "given/3 rejects params that are neither a map nor nil" do
      assert_raise FunctionClauseError, fn ->
        HTTP.interaction("x") |> HTTP.given("s", bad("x"))
      end
    end

    test "with_request/4 rejects a bad method" do
      for method <- [123, nil, true, false] do
        assert_raise FunctionClauseError, fn ->
          HTTP.interaction("x") |> HTTP.with_request(bad(method), "/")
        end
      end
    end

    test "with_request/4 rejects a bad path" do
      assert_raise FunctionClauseError, fn ->
        HTTP.interaction("x") |> HTTP.with_request(:get, bad(123))
      end
    end

    test "will_respond_with/3 rejects a bad status" do
      for status <- [0, "200", 99, 600, -1, 200.0] do
        assert_raise FunctionClauseError, fn ->
          HTTP.interaction("x") |> HTTP.will_respond_with(bad(status))
        end
      end
    end

    test "will_respond_with/3 accepts the status range limits" do
      for status <- [100, 599] do
        assert %HTTP.Response{status: ^status} =
                 HTTP.interaction("x") |> HTTP.will_respond_with(status) |> Map.fetch!(:response)
      end
    end

    test "with_request/4 rejects a :query or :headers that is not a map or a list of pairs" do
      for key <- [:query, :headers],
          value <- [
            "a=1",
            {"accept", "x"},
            :accept,
            nil,
            42,
            [:accept],
            ["accept"],
            [{"accept"}],
            [{"accept", "x", "y"}],
            [{"accept", "x"}, :oops],
            [{"accept", "x"} | :tail],
            [{1, "x"}],
            [{nil, "x"}],
            [{true, "x"}],
            [{%{}, "x"}],
            [{["a"], "x"}]
          ] do
        assert_raise ArgumentError, ~r/option #{inspect(key)} must be a map or a list/, fn ->
          HTTP.interaction("x") |> HTTP.with_request(:get, "/", [{key, bad(value)}])
        end
      end
    end

    test "will_respond_with/3 rejects a :headers that is not a map or a list of pairs" do
      for headers <- [
            {"x-id", "1"},
            "x-id: 1",
            :x,
            nil,
            [:x],
            [{"x-id"}],
            [{"x-id", "1", "2"}],
            [{"x-id", "1"} | :tail],
            [{1, "1"}],
            [{nil, "1"}]
          ] do
        assert_raise ArgumentError, ~r/option :headers must be a map or a list/, fn ->
          HTTP.interaction("x") |> HTTP.will_respond_with(200, headers: bad(headers))
        end
      end
    end

    test "the error names the offending value" do
      error =
        assert_raise ArgumentError, fn ->
          HTTP.interaction("x") |> HTTP.with_request(:get, "/", query: bad([{"a", "1"}, :oops]))
        end

      assert error.message =~ ":oops"
      assert error.message =~ "keyword list"
      assert error.message =~ "{name, value}"
    end
  end

  describe "keyword lists and lists of pairs for :query and :headers" do
    defp request_of(opts) do
      %HTTP.Request{} =
        HTTP.interaction("x") |> HTTP.with_request(:get, "/", opts) |> Map.fetch!(:request)
    end

    defp response_of(opts) do
      %HTTP.Response{} =
        HTTP.interaction("x") |> HTTP.will_respond_with(200, opts) |> Map.fetch!(:response)
    end

    test "a keyword list becomes a map with string names" do
      assert request_of(headers: [accept: "json", x_id: "1"]).headers ==
               %{"accept" => "json", "x-id" => "1"}

      assert request_of(query: [page: 2, active: true]).query == %{"page" => 2, "active" => true}
      assert response_of(headers: [etag: "abc"]).headers == %{"etag" => "abc"}
    end

    test "a list of {name, value} tuples becomes a map" do
      assert request_of(headers: [{"x-id", "1"}, {"accept", "json"}]).headers ==
               %{"x-id" => "1", "accept" => "json"}

      assert request_of(query: [{"a", "1"}]).query == %{"a" => "1"}
      assert response_of(headers: [{"x-id", "1"}]).headers == %{"x-id" => "1"}
    end

    test "tuples and keywords can be mixed, and atoms and strings are both names" do
      assert request_of(headers: [{"x-id", "1"}, accept: "json"]).headers ==
               %{"x-id" => "1", "accept" => "json"}
    end

    test "an empty list is an empty map" do
      assert request_of(query: [], headers: []) |> Map.take([:query, :headers]) ==
               %{query: %{}, headers: %{}}

      assert response_of(headers: []).headers == %{}
    end

    test "a repeated name becomes multiple values, in order" do
      assert request_of(query: [tag: "a", tag: "b"]).query == %{"tag" => ["a", "b"]}

      assert request_of(query: [tag: "a", tag: "b"]).query ==
               request_of(query: %{"tag" => ["a", "b"]}).query

      assert request_of(query: [tag: "a", page: 2, tag: "b", tag: "c"]).query ==
               %{"tag" => ["a", "b", "c"], "page" => 2}

      assert response_of(headers: [{"x-out", "b"}, {"x-out", "a"}]).headers ==
               %{"x-out" => ["b", "a"]}
    end

    test "a list value is multiple values and is joined with the repeats around it" do
      assert request_of(query: [tag: ["a", "b"], tag: "c", tag: ["d"]]).query ==
               %{"tag" => ["a", "b", "c", "d"]}

      assert request_of(query: [tag: ["a"]]).query == %{"tag" => ["a"]}
      assert request_of(query: [tag: ["a", "b"]]).query == %{"tag" => ["a", "b"]}
    end

    test "an empty list value is kept alone, and adds nothing next to other values" do
      assert request_of(query: [tag: []]).query == %{"tag" => []}
      assert request_of(query: [tag: [], tag: "a"]).query == %{"tag" => ["a"]}
    end

    test "atom header names are dashed and lower-cased like Req does, string names are kept" do
      assert request_of(headers: [content_type: "a/b", x_request_id: "1", Accept: "x"]).headers ==
               %{"content-type" => "a/b", "x-request-id" => "1", "accept" => "x"}

      assert response_of(headers: [x_out_id: "o", "X_Mixed-Case": "m"]).headers ==
               %{"x-out-id" => "o", "x-mixed-case" => "m"}

      assert request_of(headers: [{"x_kept", "1"}, {"X_Kept2", "2"}]).headers ==
               %{"x_kept" => "1", "X_Kept2" => "2"}
    end

    test "atom and string header names merge after the atom is dashed" do
      assert request_of(headers: [{"X-Request-Id", "a"}, x_request_id: "b"]).headers ==
               %{"X-Request-Id" => ["a", "b"]}

      assert request_of(headers: [{"x_request_id", "a"}, x_request_id: "b"]).headers ==
               %{"x_request_id" => "a", "x-request-id" => "b"}
    end

    test "atom query names are not dashed" do
      assert request_of(query: [page_size: 2, tag_name: "a", tag_name: "b"]).query ==
               %{"page_size" => 2, "tag_name" => ["a", "b"]}
    end

    test "query names are case-sensitive, so different case stays apart" do
      assert request_of(query: [{"Tag", "a"}, tag: "b", Tag: "c"]).query ==
               %{"Tag" => ["a", "c"], "tag" => "b"}
    end

    test "header names are case-insensitive: they are merged, the first spelling is kept" do
      assert request_of(headers: [{"X-Tag", "a"}, "x-tag": "b", "X-TAG": "c"]).headers ==
               %{"X-Tag" => ["a", "b", "c"]}

      assert response_of(headers: [{"x-out", "a"}, {"X-Out", ["b", "c"]}, other: "z"]).headers ==
               %{"x-out" => ["a", "b", "c"], "other" => "z"}

      assert request_of(headers: [{"Content-Type", "a/b"}, "content-type": "c/d"]).headers ==
               %{"Content-Type" => ["a/b", "c/d"]}
    end

    test "values are passed through as they are, for Apply to check" do
      matcher = %{"pact:matcher:type" => "type", "value" => "x"}

      assert request_of(headers: [accept: matcher, x: nil, y: 1]).headers ==
               %{"accept" => matcher, "x" => nil, "y" => 1}
    end

    test "a map is stored exactly as it was given" do
      headers = %{:x => "1", "Accept" => "json", "accept" => "dup"}
      query = %{"tag" => ["a"], page: 2}

      assert request_of(headers: headers, query: query) |> Map.take([:headers, :query]) ==
               %{headers: headers, query: query}

      assert response_of(headers: headers).headers == headers
    end

    test "the defaults are still empty maps" do
      assert request_of([]) |> Map.take([:headers, :query]) == %{headers: %{}, query: %{}}
      assert response_of([]).headers == %{}
    end
  end

  describe "replacing" do
    test "with_request/4 again replaces the previous request" do
      i =
        HTTP.interaction("x")
        |> HTTP.with_request(:get, "/a", query: %{"q" => "1"})
        |> HTTP.with_request(:post, "/b")

      assert %HTTP.Request{method: "POST", path: "/b", query: query} = i.request
      assert query == %{}
    end

    test "will_respond_with/3 again replaces the previous response" do
      i =
        HTTP.interaction("x")
        |> HTTP.will_respond_with(200, body: %{"a" => 1})
        |> HTTP.will_respond_with(404)

      assert %HTTP.Response{status: 404, body: nil} = i.response
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
