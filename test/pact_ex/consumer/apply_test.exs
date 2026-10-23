defmodule PactEx.Consumer.ApplyTest do
  use ExUnit.Case, async: true

  alias PactEx.{Consumer.Apply, HTTP, Native}
  alias PactEx.HTTP.Interaction

  @entry "PactEx.Consumer.start_mock_server/3"

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

  describe "validate/1: an empty list of values for a header or query parameter" do
    test "is rejected for any query parameter, naming it" do
      for query <- [%{"q" => []}, %{q: []}, %{"ok" => "1", "tag" => []}] do
        i =
          HTTP.interaction("empty query")
          |> HTTP.with_request(:get, "/empty", query: query)

        assert {:error, %PactEx.Error{code: -101, function: @entry, message: message}} =
                 Apply.validate(i),
               inspect(query)

        assert message =~ "request query parameter"
        assert message =~ "empty list"
        assert message =~ "empty query"

        assert message =~
                 ~s("#{Enum.find_value(query, fn
                   {k, []} -> to_string(k)
                   _ -> nil
                 end)}")
      end
    end

    test "is rejected for any request or response header, naming it" do
      headers = [%{"x" => []}, %{x: []}, %{"Content-Type" => []}, %{"ok" => "1", "X-Id" => []}]

      for headers <- headers do
        name =
          Enum.find_value(headers, fn
            {k, []} -> to_string(k)
            _ -> nil
          end)

        request =
          HTTP.interaction("empty header")
          |> HTTP.with_request(:get, "/empty", headers: headers)

        response =
          HTTP.interaction("empty header")
          |> HTTP.with_request(:get, "/empty")
          |> HTTP.will_respond_with(200, headers: headers)

        assert {:error, %PactEx.Error{code: -101, function: @entry, message: message}} =
                 Apply.validate(request),
               inspect(headers)

        assert message =~ "request header"
        assert message =~ ~s("#{name}")
        assert message =~ "empty list"

        assert {:error, %PactEx.Error{code: -101, function: @entry, message: message}} =
                 Apply.validate(response),
               inspect(headers)

        assert message =~ "response header"
        assert message =~ ~s("#{name}")
      end
    end

    test "is rejected before any native call by interaction/2 as well" do
      i =
        HTTP.interaction("empty query")
        |> HTTP.with_request(:get, "/empty", query: %{"q" => []})

      assert {:error, %PactEx.Error{code: -101, message: message}} =
               Apply.interaction(pact_ref(), i)

      assert message =~ ~s("q")
    end

    test "a value that is a list with elements is still applied" do
      pact = pact_ref()

      i =
        HTTP.interaction("lists")
        |> HTTP.with_request(:get, "/lists",
          query: %{"q" => ["a", "b"]},
          headers: %{"x" => ["1"]}
        )
        |> HTTP.will_respond_with(200)

      assert :ok = Apply.interaction(pact, i)
      port = serve(pact)

      assert %{status: 200} =
               Req.get!("http://127.0.0.1:#{port}/lists?q=a&q=b", headers: [x: "1"])
    end
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

  describe "validate/1: a Content-Type header that pact_ffi would store as an empty list" do
    defp response_with(headers, opts \\ []) do
      HTTP.interaction("probe")
      |> HTTP.with_request(:get, "/x")
      |> HTTP.will_respond_with(200, [headers: headers] ++ opts)
    end

    defp request_with(headers, opts \\ []) do
      HTTP.interaction("probe")
      |> HTTP.with_request(:post, "/x", [headers: headers] ++ opts)
    end

    @empty %{"value" => []}

    test "rejects every shape that resolves to an empty list" do
      rejected = [
        %{"Content-Type" => @empty},
        %{"Content-Type" => %{"pact:matcher:type" => "type", "value" => []}},
        %{"Content-Type" => %{"pact:matcher:type" => "regex", "regex" => ".*", "value" => []}},
        %{"Content-Type" => %{value: []}},
        %{"Content-Type" => ~s({"value":[]})},
        %{"Content-Type" => ~s( {"value" : [ ]}\n)},
        %{"Content-Type" => ~s({"pact:matcher:type":"type","value":[]})},
        # The last of two equal keys wins in serde_json.
        %{"Content-Type" => ~s({"value":"a","value":[]})},
        %{"Content-Type" => [@empty]},
        %{"Content-Type" => ["text/plain", @empty]},
        %{"Content-Type" => [@empty, @empty]},
        %{"Content-Type" => [%{"value" => ["a"]}, @empty]},
        %{"Content-Type" => [~s({"value":[]})]},
        %{"content-type" => @empty},
        %{"CONTENT-TYPE" => @empty},
        %{"Content-Type": @empty},
        %{"content-type": @empty}
      ]

      for headers <- rejected,
          body <- [nil, %{"a" => 1}, [1], "text", "", <<255, 0>>],
          build <- [&response_with/2, &request_with/2] do
        i = build.(headers, body: body)

        assert {:error, %PactEx.Error{code: -101, function: @entry, message: message}} =
                 Apply.validate(i),
               "#{inspect(headers)} with body #{inspect(body)}"

        assert message =~ ~s("Content-Type")
        assert message =~ ~s("probe")
        assert message =~ "empty list"
      end
    end

    test "rejects an empty element at any position of a list, and names its index" do
      matcher = %{"pact:matcher:type" => "type", "value" => []}

      cases = [
        {[@empty, "text/plain"], 0},
        {[matcher, %{"value" => ["a/b", "c/d"]}], 0},
        {["text/plain", @empty, "text/csv"], 1},
        {["text/plain", "text/csv", @empty], 2},
        {[~s({"value":[]}), "text/plain"], 0},
        {[@empty, @empty, "text/plain"], 0},
        {["a/b", %{"value" => ["c/d"]}, matcher, "e/f"], 2}
      ]

      for {value, index} <- cases,
          body <- [nil, %{"a" => 1}, "text", <<255, 0>>],
          build <- [&response_with/2, &request_with/2] do
        i = build.(%{"Content-Type" => value}, body: body)

        assert {:error, %PactEx.Error{code: -101, function: @entry, message: message}} =
                 Apply.validate(i),
               "#{inspect(value)} with body #{inspect(body)}"

        assert message =~ ~s("probe")
        assert message =~ ~s("Content-Type")
        assert message =~ "element #{index} "
      end
    end

    test "rejects an empty or whitespace-only value, alone or as any element" do
      blank_matcher = %{"pact:matcher:type" => "type", "value" => " "}

      cases = [
        {"", nil},
        {" ", nil},
        {"\t\r\n ", nil},
        {%{"value" => ""}, nil},
        {blank_matcher, nil},
        {%{value: ""}, nil},
        {~s({"value":""}), nil},
        {~s( {"value" : "  "}\n), nil},
        {%{"value" => [""]}, nil},
        {%{"value" => ["a/b", " "]}, nil},
        {["", "text/plain"], 0},
        {["text/plain", ""], 1},
        {["text/plain", "text/csv", " "], 2},
        {["a/b", %{"value" => ""}, "c/d"], 1},
        {[~s({"value":""}), "text/plain"], 0},
        {["a/b", %{"value" => ["c/d", ""]}], 1}
      ]

      for {value, index} <- cases,
          body <- [nil, %{"a" => 1}, "text", "", <<255, 0>>],
          build <- [&response_with/2, &request_with/2] do
        i = build.(%{"Content-Type" => value}, body: body)

        assert {:error, %PactEx.Error{code: -101, function: @entry, message: message}} =
                 Apply.validate(i),
               "#{inspect(value)} with body #{inspect(body)}"

        assert message =~ ~s("probe")
        assert message =~ ~s("Content-Type")
        assert message =~ "empty or only whitespace"
        assert message =~ if(index, do: "element #{index} ", else: "the value")
      end
    end

    test "an explicit content_type does not save an empty or blank value" do
      for value <- ["", " ", ["", "text/plain"]] do
        i = response_with(%{"Content-Type" => value}, content_type: "text/plain", body: "x")
        assert {:error, %PactEx.Error{code: -101}} = Apply.validate(i), inspect(value)
      end
    end

    test "an empty or blank explicit content_type is not an error, the header decides" do
      i = response_with(%{"Content-Type" => "text/plain"}, content_type: "", body: "x")
      assert :ok = Apply.validate(i)
    end

    test "a value with a non-whitespace character is accepted" do
      for value <- ["x", " x ", %{"value" => " x "}, ["a", "b"], %{"value" => ["a", "b"]}] do
        assert :ok = Apply.validate(response_with(%{"Content-Type" => value})), inspect(value)
      end
    end

    test "an explicit content_type does not save a list with an empty element" do
      i =
        response_with(%{"Content-Type" => [@empty, "text/plain"]},
          content_type: "text/plain",
          body: "x"
        )

      assert {:error, %PactEx.Error{code: -101}} = Apply.validate(i)
    end

    test "the message names the part" do
      assert {:error, %{message: "response header" <> _}} =
               Apply.validate(response_with(%{"Content-Type" => @empty}))

      assert {:error, %{message: "request header" <> _}} =
               Apply.validate(request_with(%{"Content-Type" => @empty}))
    end

    test "an explicit content_type does not make it acceptable" do
      i = response_with(%{"Content-Type" => @empty}, content_type: "application/json", body: %{})

      assert {:error, %PactEx.Error{code: -101}} = Apply.validate(i)
    end

    test "accepts every shape that keeps at least one value" do
      accepted = [
        "application/json",
        ["application/json", "extra"],
        %{"value" => ["application/json"]},
        %{"pact:matcher:type" => "type", "value" => "text/plain"},
        %{"pact:matcher:type" => "type", "value" => ["a/b"]},
        %{"value" => [[]]},
        %{"value" => nil},
        %{"pact:matcher:type" => "type"},
        %{"other" => []},
        ~s({"value":["application/json"]}),
        ~s({"value":"a","value":["b"]}),
        "[]",
        "not json {",
        ~s({"value":" x "}),
        ~s({"value":["a", [], "b"]}),
        [%{"value" => ["a"]}, "text/plain", %{"value" => ["b", "c"]}],
        # A number or a boolean is stringified.
        1,
        true
      ]

      for value <- accepted,
          body <- [nil, %{"a" => 1}, "text", <<255, 0>>],
          build <- [&response_with/2, &request_with/2] do
        assert :ok = Apply.validate(build.(%{"Content-Type" => value}, body: body)),
               "#{inspect(value)} with body #{inspect(body)}"
      end
    end

    test "other headers may hold an empty array" do
      i = response_with(%{"X-Other" => @empty, "Content-Type" => "text/plain"}, body: "x")
      assert :ok = Apply.validate(i)
    end

    test "a text part without a Content-Type header is unaffected" do
      assert :ok = Apply.validate(response_with(%{}, body: "x"))
    end

    test "a string that is not valid UTF-8 is left to the native call" do
      assert :ok = Apply.validate(response_with(%{"Content-Type" => <<255, 254>>}))
    end

    test "a map that cannot be encoded is left to the usual encoding error" do
      i = response_with(%{"Content-Type" => %{:value => [], "value" => []}})

      assert :ok = Apply.validate(i)

      assert {:error, %PactEx.Error{code: -101, message: message}} =
               Apply.interaction(pact_ref(), i)

      assert message =~ "cannot encode"
    end

    test "interaction/2 returns the same error" do
      i = response_with(%{"Content-Type" => @empty}, body: %{"a" => 1})

      assert {:error, %PactEx.Error{code: -101, function: @entry}} =
               Apply.interaction(pact_ref(), i)
    end
  end
end
