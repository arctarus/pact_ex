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

  describe "validate/1: values and names that cannot be applied" do
    # `validate/1` only plans: it makes no native call. So an error here proves
    # the check runs before any native call.
    test "a nil or unsupported query or header value is rejected, naming the key" do
      for value <- [nil, {:a}, :atom, ["a", nil], %{:a => 1, "a" => 2}] do
        request_q = HTTP.interaction("v") |> HTTP.with_request(:get, "/v", query: %{"k" => value})

        request_h =
          HTTP.interaction("v") |> HTTP.with_request(:get, "/v", headers: %{"k" => value})

        response =
          HTTP.interaction("v")
          |> HTTP.with_request(:get, "/v")
          |> HTTP.will_respond_with(200, headers: %{"k" => value})

        for {i, label} <- [
              {request_q, "query parameter"},
              {request_h, "request header"},
              {response, "response header"}
            ] do
          assert {:error, %PactEx.Error{code: -101, function: @entry, message: message}} =
                   Apply.validate(i),
                 "#{label} #{inspect(value)}"

          assert message =~ ~s("k")
          assert message =~ label
        end
      end
    end

    test "a name that is not a string or an atom is rejected" do
      for name <- [1, {:a}, nil, true] do
        request_q = HTTP.interaction("n") |> HTTP.with_request(:get, "/n", query: %{name => "a"})

        request_h =
          HTTP.interaction("n") |> HTTP.with_request(:get, "/n", headers: %{name => "a"})

        for i <- [request_q, request_h] do
          assert {:error, %PactEx.Error{code: -101, message: message}} = Apply.validate(i),
                 inspect(name)

          assert message =~ "name"
        end
      end
    end

    test "valid scalars, matchers and lists pass" do
      matcher = %{"pact:matcher:type" => "type", "value" => "x"}

      i =
        HTTP.interaction("ok")
        |> HTTP.with_request(:get, "/ok",
          query: %{"a" => 1, "b" => 1.5, "c" => true, "d" => matcher, "e" => ["x", 2]},
          headers: %{"h" => matcher}
        )

      assert :ok = Apply.validate(i)
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

    test "the reason depends on the side, for an empty list and for a blank value" do
      for value <- [
            @empty,
            "",
            " ",
            ["text/plain", @empty],
            ["", "text/plain"],
            %{"value" => " "}
          ] do
        assert {:error, %{message: request}} =
                 Apply.validate(request_with(%{"Content-Type" => value}))

        assert {:error, %{message: response}} =
                 Apply.validate(response_with(%{"Content-Type" => value}))

        assert request =~ "no request of this interaction can match it", inspect(value)
        refute request =~ "provider", inspect(value)
        assert response =~ "a meaningless header that no provider can produce", inspect(value)
        refute response =~ "no request", inspect(value)

        for message <- [request, response] do
          refute message =~ "500", inspect(value)
          refute message =~ "every request", inspect(value)
        end
      end
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

    test "a map that cannot be encoded returns the usual encoding error" do
      i = response_with(%{"Content-Type" => %{:value => [], "value" => []}})

      for result <- [Apply.validate(i), Apply.interaction(pact_ref(), i)] do
        assert {:error, %PactEx.Error{code: -101, message: message}} = result
        assert message =~ "cannot encode"
      end
    end

    test "interaction/2 returns the same error" do
      i = response_with(%{"Content-Type" => @empty}, body: %{"a" => 1})

      assert {:error, %PactEx.Error{code: -101, function: @entry}} =
               Apply.interaction(pact_ref(), i)
    end
  end

  describe "plan_body/4" do
    @message_entry "PactEx.Message.run/4"
    @label ~s(contents of message "m")

    defp plan_body(body, content_type \\ nil),
      do: Apply.plan_body(body, content_type, @label, @message_entry)

    test "a map is JSON text" do
      assert {:ok, {:text, "application/json", ~s({"a":1})}} = plan_body(%{"a" => 1})
    end

    test "a list is JSON text" do
      assert {:ok, {:text, "application/json", ~s([1,"a"])}} = plan_body([1, "a"])
    end

    test "a UTF-8 string without NUL is text" do
      assert {:ok, {:text, "text/plain", "hello"}} = plan_body("hello")
    end

    test "any other binary is binary" do
      assert {:ok, {:binary, "application/octet-stream", <<0xFF, 0x00>>}} =
               plan_body(<<0xFF, 0x00>>)
    end

    test "the explicit content type is trimmed and used" do
      assert {:ok, {:text, "text/csv", "hello"}} = plan_body("hello", " text/csv ")
    end

    test "an explicit content type that pact_models cannot parse falls back to the default" do
      assert {:ok, {:text, "text/plain", "hello"}} = plan_body("hello", "not a type")
    end

    test "no body is nil" do
      assert {:ok, nil} = plan_body(nil)
      assert {:ok, nil} = plan_body(nil, "text/csv")
    end

    test "an invalid XML description is rejected with the entry point and the label" do
      assert {:error, %PactEx.Error{code: -101, function: @message_entry, message: message}} =
               plan_body(%{"root" => 1}, "application/xml")

      assert message =~ ~s(contents of message "m" cannot be sent)
    end

    test "a repeated key is rejected with the entry point and the label" do
      assert {:error, %PactEx.Error{code: -101, function: @message_entry, message: message}} =
               plan_body(%{:a => 1, "a" => 2})

      assert message =~ ~s(cannot encode contents of message "m" as JSON)
    end

    test "an unsupported body is rejected with the entry point and the label" do
      assert {:error, %PactEx.Error{code: -101, function: @message_entry, message: message}} =
               plan_body(123)

      assert message =~ ~s(unsupported contents of message "m": 123)
    end
  end

  describe "plan_json/3" do
    @message_entry "PactEx.Message.run/4"
    @label ~s(metadata "k" of message "m")

    defp plan_json(term), do: Apply.plan_json(term, @label, @message_entry)

    test "a map is encoded" do
      assert {:ok, ~s({"a":1})} = plan_json(%{"a" => 1})
    end

    test "a string is encoded as a JSON string" do
      assert {:ok, ~s("5")} = plan_json("5")
    end

    test "a repeated key is rejected with the entry point and the label" do
      assert {:error, %PactEx.Error{code: -101, function: @message_entry, message: message}} =
               plan_json(%{"a" => %{:b => 1, "b" => 2}})

      assert message =~ ~s(cannot encode metadata "k" of message "m" as JSON)
    end

    test "a value JSON cannot encode is rejected with the entry point and the label" do
      assert {:error, %PactEx.Error{code: -101, function: @message_entry, message: message}} =
               plan_json({1, 2})

      assert message =~ ~s(cannot encode metadata "k" of message "m" as JSON)
    end
  end
end
