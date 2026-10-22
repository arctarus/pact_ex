# test/pact_ex/native/mock_server_test.exs
defmodule PactEx.Native.MockServerTest do
  use ExUnit.Case, async: true
  alias PactEx.Native

  defp ping_pact do
    pact = Native.new_pact("native-consumer", "native-provider")
    :ok = Native.with_specification(pact, :v4)
    i = Native.new_interaction(pact, "a ping")
    :ok = Native.with_request(i, "GET", "/ping")
    :ok = Native.response_status(i, "200")
    :ok = Native.with_body(i, :response, "text/plain", "pong")
    pact
  end

  @tag :tmp_dir
  test "serves the interaction, reports a match and writes the pact", %{tmp_dir: dir} do
    {:ok, port} = Native.create_mock_server(ping_pact(), "127.0.0.1", 0, "http", nil)
    assert %{status: 200, body: "pong"} = Req.get!("http://127.0.0.1:#{port}/ping")
    assert Native.mock_server_matched(port)
    assert Native.write_pact_file(port, dir, false) == :ok
    assert File.exists?(Path.join(dir, "native-consumer-native-provider.json"))
    assert Native.cleanup_mock_server(port)
  end

  test "reports missing requests as mismatches" do
    {:ok, port} = Native.create_mock_server(ping_pact(), "127.0.0.1", 0, "http", nil)
    refute Native.mock_server_matched(port)
    assert Native.mock_server_mismatches(port) =~ "missing-request"
    assert Native.cleanup_mock_server(port)
  end

  test "invalid transport config JSON returns code -2" do
    assert {:error, %{function: "pactffi_create_mock_server_for_transport", code: -2}} =
             Native.create_mock_server(ping_pact(), "127.0.0.1", 0, "http", "not json")
  end

  test "binary body round-trips byte for byte" do
    pact = Native.new_pact("native-consumer", "native-provider")
    i = Native.new_interaction(pact, "binary")
    :ok = Native.with_request(i, "GET", "/bin")
    :ok = Native.response_status(i, "200")
    :ok = Native.with_binary_body(i, :response, "application/octet-stream", <<0, 255, 1>>)
    {:ok, port} = Native.create_mock_server(pact, "127.0.0.1", 0, "http", nil)
    assert %{body: <<0, 255, 1>>} = Req.get!("http://127.0.0.1:#{port}/bin", decode_body: false)
    assert Native.cleanup_mock_server(port)
  end

  test "query parameters and request/response headers are served and matched" do
    pact = Native.new_pact("native-consumer", "native-provider")
    i = Native.new_interaction(pact, "search")
    :ok = Native.with_request(i, "GET", "/search")
    :ok = Native.with_query_parameter(i, "tag", 0, "a")
    :ok = Native.with_query_parameter(i, "tag", 1, "b")
    :ok = Native.with_header(i, :request, "x-id", 0, "1")
    :ok = Native.response_status(i, "204")
    :ok = Native.with_header(i, :response, "x-reply", 0, "yes")
    {:ok, port} = Native.create_mock_server(pact, "127.0.0.1", 0, "http", nil)

    resp =
      Req.get!("http://127.0.0.1:#{port}/search?tag=a&tag=b",
        headers: [{"x-id", "1"}],
        retry: false
      )

    assert resp.status == 204
    assert Req.Response.get_header(resp, "x-reply") == ["yes"]
    assert Native.mock_server_matched(port)
    assert Native.cleanup_mock_server(port)
  end

  test "interaction builders return an error once the mock server has started" do
    pact = Native.new_pact("native-consumer", "native-provider")
    i = Native.new_interaction(pact, "late")
    :ok = Native.with_request(i, "GET", "/late")
    {:ok, port} = Native.create_mock_server(pact, "127.0.0.1", 0, "http", nil)
    assert {:error, %{function: "pactffi_with_request"}} = Native.with_request(i, "GET", "/other")

    assert {:error, %{function: "pactffi_with_header_v2"}} =
             Native.with_header(i, :request, "x", 0, "y")

    assert {:error, %{function: "pactffi_with_query_parameter_v2"}} =
             Native.with_query_parameter(i, "q", 0, "v")

    assert {:error, %{function: "pactffi_with_body"}} =
             Native.with_body(i, :response, "text/plain", "x")

    assert {:error, %{function: "pactffi_with_binary_body"}} =
             Native.with_binary_body(i, :response, "application/octet-stream", <<1>>)

    assert {:error, %{function: "pactffi_response_status_v2"}} = Native.response_status(i, "500")
    assert Native.cleanup_mock_server(port)
  end

  test "string arguments with NUL bytes are rejected without calling the FFI" do
    i = Native.new_interaction(Native.new_pact("native-consumer", "native-provider"), "nul")
    assert {:error, %{code: -100}} = Native.with_request(i, "GET", "/a\0b")
    assert {:error, %{code: -100}} = Native.with_body(i, :response, "text/plain", "a\0b")
  end

  test "an unknown part atom raises ArgumentError" do
    i = Native.new_interaction(Native.new_pact("native-consumer", "native-provider"), "part")
    assert_raise ArgumentError, fn -> Native.with_header(i, :both, "x", 0, "y") end
  end

  @tag :tmp_dir
  test "unknown ports: matched false, mismatches nil, write code 3, cleanup false", %{
    tmp_dir: dir
  } do
    refute Native.mock_server_matched(1)
    assert Native.mock_server_mismatches(1) == nil

    assert {:error, %{function: "pactffi_write_pact_file", code: 3}} =
             Native.write_pact_file(1, dir, false)

    refute Native.cleanup_mock_server(1)
  end

  describe "additional error paths" do
    setup do
      pact = Native.new_pact("native-consumer", "native-provider")
      %{pact: pact, interaction: Native.new_interaction(pact, "extra")}
    end

    test "every builder rejects NUL bytes without calling the FFI", %{interaction: i} do
      assert {:error, %{function: "pactffi_with_request", code: -100}} =
               Native.with_request(i, "G\0ET", "/a")

      assert {:error, %{function: "pactffi_with_query_parameter_v2", code: -100}} =
               Native.with_query_parameter(i, "n\0", 0, "v")

      assert {:error, %{function: "pactffi_with_query_parameter_v2", code: -100}} =
               Native.with_query_parameter(i, "n", 0, "v\0")

      assert {:error, %{function: "pactffi_with_header_v2", code: -100}} =
               Native.with_header(i, :request, "x\0", 0, "y")

      assert {:error, %{function: "pactffi_with_header_v2", code: -100}} =
               Native.with_header(i, :request, "x", 0, "y\0")

      assert {:error, %{function: "pactffi_with_body", code: -100}} =
               Native.with_body(i, :response, "text/pl\0ain", "x")

      assert {:error, %{function: "pactffi_with_binary_body", code: -100}} =
               Native.with_binary_body(i, :response, "application/oct\0et-stream", <<1>>)

      assert {:error, %{function: "pactffi_response_status_v2", code: -100}} =
               Native.response_status(i, "2\x000")
    end

    test "body builders reject unknown part atoms", %{interaction: i} do
      assert_raise ArgumentError, fn -> Native.with_body(i, :both, "text/plain", "x") end

      assert_raise ArgumentError, fn ->
        Native.with_binary_body(i, :both, "application/octet-stream", <<1>>)
      end

      assert_raise ArgumentError, fn -> Native.with_header(i, "request", "x", 0, "y") end
    end

    test "negative header and query indexes raise ArgumentError", %{interaction: i} do
      assert_raise ArgumentError, fn -> Native.with_query_parameter(i, "q", -1, "v") end
      assert_raise ArgumentError, fn -> Native.with_header(i, :request, "x", -1, "y") end
    end

    test "with_binary_body with an empty body serves an empty response" do
      pact = Native.new_pact("native-consumer", "native-provider")
      i = Native.new_interaction(pact, "empty binary")
      :ok = Native.with_request(i, "GET", "/empty")
      :ok = Native.response_status(i, "200")
      :ok = Native.with_binary_body(i, :response, "application/octet-stream", <<>>)
      {:ok, port} = Native.create_mock_server(pact, "127.0.0.1", 0, "http", nil)

      resp = Req.get!("http://127.0.0.1:#{port}/empty", decode_body: false, retry: false)
      assert resp.status == 200
      assert resp.body == ""
      assert Req.Response.get_header(resp, "content-type") == ["application/octet-stream"]
      assert Native.mock_server_matched(port)
      assert Native.cleanup_mock_server(port)
    end

    test "create_mock_server rejects NUL bytes in every string argument", %{pact: pact} do
      fun = "pactffi_create_mock_server_for_transport"

      assert {:error, %{function: ^fun, code: -100}} =
               Native.create_mock_server(pact, "127.0.0.1\0", 0, "http", nil)

      assert {:error, %{function: ^fun, code: -100}} =
               Native.create_mock_server(pact, "127.0.0.1", 0, "ht\0tp", nil)

      assert {:error, %{function: ^fun, code: -100}} =
               Native.create_mock_server(pact, "127.0.0.1", 0, "http", "{}\0")
    end

    test "create_mock_server rejects an out-of-range port", %{pact: pact} do
      assert_raise ArgumentError, fn ->
        Native.create_mock_server(pact, "127.0.0.1", 70_000, "http", nil)
      end
    end

    test "port-taking NIFs reject ports outside 0..65535", %{pact: pact} do
      for port <- [-1, 65_536, 70_000] do
        assert_raise ArgumentError, fn ->
          Native.create_mock_server(pact, "127.0.0.1", port, "http", nil)
        end

        assert_raise ArgumentError, fn -> Native.mock_server_matched(port) end
        assert_raise ArgumentError, fn -> Native.mock_server_mismatches(port) end
        assert_raise ArgumentError, fn -> Native.write_pact_file(port, "pacts", false) end
        assert_raise ArgumentError, fn -> Native.cleanup_mock_server(port) end
      end
    end

    test "create_mock_server returns -5 for an invalid address", %{pact: pact} do
      # Not an IP literal, so pact_ffi resolves it with getaddrinfo. A name over
      # 255 bytes is rejected locally by every resolver, with no network lookup.
      host = String.duplicate("a", 300)

      assert {:error, %{function: "pactffi_create_mock_server_for_transport", code: -5}} =
               Native.create_mock_server(pact, host, 0, "http", nil)
    end

    test "create_mock_server returns -3 when the port is already in use", %{pact: pact} do
      {:ok, port} = Native.create_mock_server(pact, "127.0.0.1", 0, "http", nil)

      other = Native.new_pact("native-consumer", "native-provider")

      assert {:error, %{function: "pactffi_create_mock_server_for_transport", code: -3}} =
               Native.create_mock_server(other, "127.0.0.1", port, "http", nil)

      assert Native.cleanup_mock_server(port)
    end

    test "create_mock_server accepts a valid transport config", %{pact: pact} do
      assert {:ok, port} = Native.create_mock_server(pact, "127.0.0.1", 0, "http", "{}")
      assert Native.cleanup_mock_server(port)
    end

    test "mock_server_mismatches returns an empty list once every request matched" do
      {:ok, port} = Native.create_mock_server(ping_pact(), "127.0.0.1", 0, "http", nil)
      assert %{status: 200} = Req.get!("http://127.0.0.1:#{port}/ping", retry: false)
      assert Native.mock_server_mismatches(port) == "[]"
      assert Native.cleanup_mock_server(port)
    end

    test "mock_server_mismatches reports an unexpected request" do
      {:ok, port} = Native.create_mock_server(ping_pact(), "127.0.0.1", 0, "http", nil)
      assert %{status: 500} = Req.get!("http://127.0.0.1:#{port}/other", retry: false)
      refute Native.mock_server_matched(port)
      assert Native.mock_server_mismatches(port) =~ "request-not-found"
      assert Native.cleanup_mock_server(port)
    end

    test "write_pact_file rejects a NUL byte in the directory" do
      assert {:error, %{function: "pactffi_write_pact_file", code: -100}} =
               Native.write_pact_file(1, "a\0b", false)
    end

    @tag :tmp_dir
    test "write_pact_file returns code 2 when the pact cannot be written", %{tmp_dir: dir} do
      blocker = Path.join(dir, "not-a-dir")
      File.write!(blocker, "")

      {:ok, port} = Native.create_mock_server(ping_pact(), "127.0.0.1", 0, "http", nil)

      assert {:error, %{function: "pactffi_write_pact_file", code: 2}} =
               Native.write_pact_file(port, blocker, false)

      assert Native.cleanup_mock_server(port)
    end

    @tag :tmp_dir
    test "write_pact_file merges when overwrite is false and replaces when true", %{tmp_dir: dir} do
      path = Path.join(dir, "native-consumer-native-provider.json")

      descriptions = fn ->
        path
        |> File.read!()
        |> JSON.decode!()
        |> Map.fetch!("interactions")
        |> Enum.map(& &1["description"])
        |> Enum.sort()
      end

      write = fn description, overwrite ->
        pact = Native.new_pact("native-consumer", "native-provider")
        :ok = Native.with_specification(pact, :v4)
        i = Native.new_interaction(pact, description)
        :ok = Native.with_request(i, "GET", "/#{description}")
        :ok = Native.response_status(i, "200")
        {:ok, port} = Native.create_mock_server(pact, "127.0.0.1", 0, "http", nil)
        assert %{status: 200} = Req.get!("http://127.0.0.1:#{port}/#{description}", retry: false)
        assert Native.write_pact_file(port, dir, overwrite) == :ok
        assert Native.cleanup_mock_server(port)
      end

      write.("one", false)
      assert descriptions.() == ["one"]

      write.("two", false)
      assert descriptions.() == ["one", "two"]

      write.("three", true)
      assert descriptions.() == ["three"]
    end

    test "cleanup_mock_server stops the server and a second cleanup returns false" do
      {:ok, port} = Native.create_mock_server(ping_pact(), "127.0.0.1", 0, "http", nil)
      assert Native.cleanup_mock_server(port)
      refute Native.cleanup_mock_server(port)
      refute Native.mock_server_matched(port)
      assert Native.mock_server_mismatches(port) == nil
    end
  end
end
