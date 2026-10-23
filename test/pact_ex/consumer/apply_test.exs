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

  describe "validate/1: a Content-Type header that pact_ffi would store as an empty list" do
    @entry "PactEx.Consumer.start_mock_server/3"

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
        "",
        "not json {",
        # An empty list of calls writes no header at all.
        [],
        # A later element with index above 0 refills the list.
        [@empty, "text/plain"],
        [%{"pact:matcher:type" => "type", "value" => []}, %{"value" => ["a/b", "c/d"]}],
        [@empty, @empty, "text/plain"],
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
