defmodule PactEx.Verifier.EndpointTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias PactEx.Verifier.Endpoint

  defp call(opts, path, body) do
    :post
    |> conn(path, JSON.encode!(body))
    |> put_req_header("content-type", "application/json")
    |> Endpoint.call(Endpoint.init(opts))
  end

  defp state(opts, state \\ "s", action \\ "setup") do
    call(opts, "/_pact/state", %{"state" => state, "params" => %{}, "action" => action})
  end

  describe "POST /_pact/state" do
    test "passes state, params and action, and returns the map as JSON" do
      parent = self()

      handler = fn state, params, action ->
        send(parent, {state, params, action})
        {:ok, %{"id" => 7}}
      end

      conn =
        call(%{state_handler: handler}, "/_pact/state", %{
          "state" => "user exists",
          "params" => %{"a" => 1},
          "action" => "setup"
        })

      assert conn.status == 200
      assert JSON.decode!(conn.resp_body) == %{"id" => 7}
      assert_received {"user exists", %{"a" => 1}, :setup}
    end

    test "passes :teardown, and :ok answers an empty object" do
      parent = self()

      handler = fn _state, _params, action ->
        send(parent, action)
        :ok
      end

      conn = state(%{state_handler: handler}, "s", "teardown")
      assert conn.status == 200
      assert JSON.decode!(conn.resp_body) == %{}
      assert_received :teardown
    end

    test "the empty state of an interaction without states does not call the handler" do
      conn = state(%{state_handler: fn _, _, _ -> raise "must not run" end}, "")
      assert conn.status == 200
      assert JSON.decode!(conn.resp_body) == %{}
    end

    test "without a handler it answers 200" do
      assert state(%{}).status == 200
    end

    test "a raising handler returns 422 and reports the reason" do
      ref = make_ref()
      opts = %{state_handler: fn _, _, _ -> raise "nope" end, report_to: {self(), ref}}

      conn = state(opts, "db ready")
      assert conn.status == 422
      assert conn.resp_body =~ "nope"
      assert_received {:pact_ex_callback_error, ^ref, text}
      assert text =~ "db ready" and text =~ "setup" and text =~ "nope"
    end

    test "an error tuple, a throw and an unexpected return are 422, never 5xx" do
      for handler <- [
            fn _, _, _ -> {:error, :db_down} end,
            fn _, _, _ -> throw(:oops) end,
            fn _, _, _ -> 42 end
          ] do
        assert state(%{state_handler: handler}).status == 422
      end

      assert state(%{state_handler: fn _, _, _ -> {:error, :db_down} end}).resp_body =~ "db_down"
    end
  end

  describe "POST /_pact/messages" do
    test "returns JSON contents and the metadata as a base64 header" do
      providers = %{"weather" => fn [%{name: "cold"}] -> {%{"temp" => 1}, %{"queue" => "w"}} end}

      conn =
        call(%{message_providers: providers}, "/_pact/messages", %{
          "description" => "weather",
          "providerStates" => [%{"name" => "cold", "params" => %{}}]
        })

      assert conn.status == 200
      assert JSON.decode!(conn.resp_body) == %{"temp" => 1}
      assert hd(get_resp_header(conn, "content-type")) =~ "application/json"
      [meta] = get_resp_header(conn, "pact-message-metadata")
      assert meta |> Base.decode64!() |> JSON.decode!() == %{"queue" => "w"}
    end

    test "provider states without params get an empty map" do
      parent = self()

      providers = %{
        "m" => fn states ->
          send(parent, states)
          %{}
        end
      }

      call(%{message_providers: providers}, "/_pact/messages", %{
        "description" => "m",
        "providerStates" => [%{"name" => "s"}]
      })

      assert_received [%{name: "s", params: %{}}]
    end

    test "an unknown description uses the fallback, else 404 and a report" do
      ref = make_ref()
      fallback = fn _ -> %{"f" => true} end

      assert call(%{fallback: fallback}, "/_pact/messages", %{"description" => "x"}).status == 200

      conn = call(%{report_to: {self(), ref}}, "/_pact/messages", %{"description" => "x"})
      assert conn.status == 404
      assert conn.resp_body =~ "no message provider for x"
      assert_received {:pact_ex_callback_error, ^ref, "no message provider for \"x\""}
    end

    test "binary contents keep their content type" do
      providers = %{"bin" => fn _ -> {<<1, 2>>, "application/octet-stream"} end}
      conn = call(%{message_providers: providers}, "/_pact/messages", %{"description" => "bin"})

      assert conn.resp_body == <<1, 2>>
      assert hd(get_resp_header(conn, "content-type")) =~ "application/octet-stream"
    end

    test "binary contents with metadata, and a plain string as text" do
      providers = %{
        "both" => fn _ -> {{<<1>>, "application/x-bin"}, %{"k" => "v"}} end,
        "text" => fn _ -> "hello" end
      }

      both = call(%{message_providers: providers}, "/_pact/messages", %{"description" => "both"})
      assert both.resp_body == <<1>>
      assert [_] = get_resp_header(both, "pact-message-metadata")

      text = call(%{message_providers: providers}, "/_pact/messages", %{"description" => "text"})
      assert text.resp_body == "hello"
      assert hd(get_resp_header(text, "content-type")) =~ "text/plain"
    end

    test "a result that is not a message is 422 and reported, never a 500" do
      ref = make_ref()

      for {result, text} <- [
            {{:ok, %{"a" => 1}}, "got: {:ok"},
            {{:error, :sensor_down}, ":sensor_down"},
            {%{"a" => {1, 2}}, "{1, 2}"},
            {{%{"a" => 1}, %{"pid" => self()}}, "#PID<"},
            {42, "got: 42"}
          ] do
        providers = %{"m" => fn _ -> result end}

        conn =
          call(%{message_providers: providers, report_to: {self(), ref}}, "/_pact/messages", %{
            "description" => "m"
          })

        assert conn.status == 422, inspect(result)
        assert_received {:pact_ex_callback_error, ^ref, reason}
        assert reason =~ text, inspect(result)
      end
    end

    test "a raising provider is 422 and reported" do
      ref = make_ref()
      providers = %{"m" => fn _ -> raise "broken" end}

      conn =
        call(%{message_providers: providers, report_to: {self(), ref}}, "/_pact/messages", %{
          "description" => "m"
        })

      assert conn.status == 422
      assert_received {:pact_ex_callback_error, ^ref, text}
      assert text =~ "broken"
    end
  end

  test "any other path is 404" do
    assert call(%{}, "/nope", %{}).status == 404
  end
end
