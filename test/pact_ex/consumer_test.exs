defmodule PactEx.ConsumerTest do
  use ExUnit.Case, async: true
  import PactEx.Matchers
  alias PactEx.{Consumer, HTTP}

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    %{pact: PactEx.new("consumer-test", "provider-test", pact_dir: dir)}
  end

  defp bad(value), do: Function.identity(value)

  defp pact_path(dir), do: Path.join(dir, "consumer-test-provider-test.json")

  defp read_pact(dir), do: dir |> pact_path() |> File.read!() |> JSON.decode!()

  defp body_of(dir, part), do: hd(read_pact(dir)["interactions"])[part]["body"]

  defp simple(description, path) do
    HTTP.interaction(description)
    |> HTTP.with_request(:get, path)
    |> HTTP.will_respond_with(200)
  end

  describe "run/4" do
    test "GET with query, headers and matchers writes a pact with matching rules", %{
      pact: pact,
      tmp_dir: dir
    } do
      i =
        HTTP.interaction("get user")
        |> HTTP.given("user exists", %{"id" => "1"})
        |> HTTP.with_request(:get, "/users/1",
          query: %{"full" => "true"},
          headers: %{"accept" => "application/json"}
        )
        |> HTTP.will_respond_with(200, body: %{"id" => like(1), "name" => like("Ann")})

      assert :ok =
               Consumer.run(pact, [i], fn mock ->
                 assert %{status: 200, body: %{"id" => 1}} =
                          Req.get!(mock.url <> "/users/1",
                            params: [full: "true"],
                            headers: [accept: "application/json"]
                          )
               end)

      [written] = read_pact(dir)["interactions"]
      assert [%{"name" => "user exists", "params" => %{"id" => "1"}}] = written["providerStates"]
      assert get_in(written, ["response", "matchingRules", "body", "$.id"])
    end

    test "POST with JSON request body", %{pact: pact} do
      i =
        HTTP.interaction("create user")
        |> HTTP.with_request(:post, "/users", body: %{"name" => like("Ann")})
        |> HTTP.will_respond_with(201)

      assert :ok =
               Consumer.run(pact, [i], fn m ->
                 assert %{status: 201} = Req.post!(m.url <> "/users", json: %{name: "Bob"})
               end)
    end

    test "raw text body keeps its content type", %{pact: pact, tmp_dir: dir} do
      i =
        HTTP.interaction("plain")
        |> HTTP.with_request(:get, "/txt")
        |> HTTP.will_respond_with(200, body: "<a>hi</a>", content_type: "application/xml")

      assert :ok =
               Consumer.run(pact, [i], fn m ->
                 resp = Req.get!(m.url <> "/txt", decode_body: false)
                 assert resp.body == "<a>hi</a>"
                 assert Req.Response.get_header(resp, "content-type") |> hd() =~ "application/xml"
               end)

      assert %{"content" => "<a>hi</a>", "contentType" => "application/xml", "encoded" => false} =
               body_of(dir, "response")
    end

    test "multi-valued query params and matcher header values", %{pact: pact} do
      i =
        HTTP.interaction("multi")
        |> HTTP.with_request(:get, "/search",
          query: %{"tag" => ["a", "b"]},
          headers: %{"x-id" => regex("abc-1", "^abc-\\d+$")}
        )
        |> HTTP.will_respond_with(200)

      assert :ok =
               Consumer.run(pact, [i], fn m ->
                 Req.get!(m.url <> "/search?tag=a&tag=b", headers: [{"x-id", "abc-42"}])
               end)
    end

    test "an interaction never exercised returns a MismatchError and writes nothing", %{
      pact: pact,
      tmp_dir: dir
    } do
      i = simple("never", "/never")

      assert {:error, %PactEx.MismatchError{mismatches: [%{"type" => "missing-request"}]} = e} =
               Consumer.run(pact, [i], fn _ -> :ok end)

      assert Exception.message(e) =~ "/never"
      refute File.exists?(pact_path(dir))
    end

    test "an exception in the test function stops the server, writes nothing and re-raises", %{
      pact: pact,
      tmp_dir: dir
    } do
      i = simple("boom", "/boom")
      parent = self()

      assert_raise RuntimeError, "boom", fn ->
        Consumer.run(pact, [i], fn m ->
          send(parent, {:port, m.port})
          raise "boom"
        end)
      end

      assert_received {:port, port}
      # Already cleaned up by run/4, so a second cleanup finds no server.
      refute PactEx.Native.cleanup_mock_server(port)
      refute File.exists?(pact_path(dir))
    end

    test "a throw or exit in the test function also stops the server", %{pact: pact, tmp_dir: dir} do
      i = simple("escape", "/escape")
      parent = self()

      assert :oops ==
               catch_throw(
                 Consumer.run(pact, [i], fn m ->
                   send(parent, {:port, m.port})
                   throw(:oops)
                 end)
               )

      assert_received {:port, port}
      refute PactEx.Native.cleanup_mock_server(port)

      assert {:shutdown, :bye} ==
               catch_exit(
                 Consumer.run(pact, [i], fn m ->
                   send(parent, {:port, m.port})
                   exit({:shutdown, :bye})
                 end)
               )

      assert_received {:port, port}
      refute PactEx.Native.cleanup_mock_server(port)
      refute File.exists?(pact_path(dir))
    end

    test "the return value of the test function is ignored", %{pact: pact} do
      i = simple("ignored", "/ignored")

      assert :ok =
               Consumer.run(pact, [i], fn m ->
                 Req.get!(m.url <> "/ignored")
                 {:something, "else"}
               end)
    end

    test "spec :v3 is written into metadata", %{tmp_dir: dir} do
      pact = PactEx.new("consumer-test", "provider-test", pact_dir: dir, spec: :v3)
      i = simple("v3", "/v3")
      assert :ok = Consumer.run(pact, [i], fn m -> Req.get!(m.url <> "/v3") end)
      assert read_pact(dir)["metadata"]["pactSpecification"]["version"] == "3.0.0"
    end

    test "spec :v2 is written into metadata", %{tmp_dir: dir} do
      pact = PactEx.new("consumer-test", "provider-test", pact_dir: dir, spec: :v2)
      i = simple("v2", "/v2")
      assert :ok = Consumer.run(pact, [i], fn m -> Req.get!(m.url <> "/v2") end)
      assert read_pact(dir)["metadata"]["pactSpecification"]["version"] == "2.0.0"
    end

    test "the default spec is v4", %{pact: pact, tmp_dir: dir} do
      i = simple("v4", "/v4")
      assert :ok = Consumer.run(pact, [i], fn m -> Req.get!(m.url <> "/v4") end)
      assert read_pact(dir)["metadata"]["pactSpecification"]["version"] == "4.0"
    end

    test "a request with the wrong body returns a MismatchError naming the body mismatch", %{
      pact: pact,
      tmp_dir: dir
    } do
      i =
        HTTP.interaction("create")
        |> HTTP.with_request(:post, "/things", body: %{"name" => "exact"})
        |> HTTP.will_respond_with(201)

      assert {:error, %PactEx.MismatchError{mismatches: mismatches} = e} =
               Consumer.run(pact, [i], fn m ->
                 Req.post!(m.url <> "/things", json: %{name: "other"}, retry: false)
               end)

      assert Enum.any?(mismatches, &(&1["type"] in ["request-mismatch", "missing-request"]))
      assert Exception.message(e) =~ "/things"
      refute File.exists?(pact_path(dir))
    end

    test "an unexpected request returns a MismatchError", %{pact: pact, tmp_dir: dir} do
      i = simple("expected", "/expected")

      assert {:error, %PactEx.MismatchError{mismatches: mismatches}} =
               Consumer.run(pact, [i], fn m ->
                 Req.get!(m.url <> "/expected")
                 Req.get!(m.url <> "/surprise", retry: false)
               end)

      assert Enum.any?(mismatches, &(&1["type"] == "request-not-found"))
      refute File.exists?(pact_path(dir))
    end

    test "writing the pact can fail, returning a PactEx.Error", %{tmp_dir: dir} do
      blocker = Path.join(dir, "blocker")
      File.write!(blocker, "not a directory")
      pact = PactEx.new("consumer-test", "provider-test", pact_dir: blocker)
      i = simple("unwritable", "/unwritable")

      assert {:error, %PactEx.Error{function: "pactffi_write_pact_file"}} =
               Consumer.run(pact, [i], fn m -> Req.get!(m.url <> "/unwritable") end)
    end

    test "creates a missing pact directory", %{tmp_dir: dir} do
      nested = Path.join([dir, "a", "b"])
      pact = PactEx.new("consumer-test", "provider-test", pact_dir: nested)
      i = simple("nested", "/nested")
      assert :ok = Consumer.run(pact, [i], fn m -> Req.get!(m.url <> "/nested") end)
      assert File.exists?(pact_path(nested))
    end

    test "returns the start error and never calls the test function", %{pact: pact} do
      i = HTTP.interaction("bad") |> HTTP.with_request(:get, "/bad\0path")
      parent = self()

      assert {:error, %PactEx.Error{code: -100}} =
               Consumer.run(pact, [i], fn _ -> send(parent, :called) end)

      refute_received :called
    end

    test "rejects a test function that is not a 1-arity function", %{pact: pact} do
      i = simple("arity", "/arity")
      assert_raise FunctionClauseError, fn -> Consumer.run(pact, [i], bad(fn -> :ok end)) end
      assert_raise FunctionClauseError, fn -> Consumer.run(pact, [i], bad(:not_a_fun)) end
    end

    test "rejects unknown options", %{pact: pact} do
      i = simple("opts", "/opts")
      assert_raise ArgumentError, fn -> Consumer.run(pact, [i], fn _ -> :ok end, bad(hots: 1)) end
    end

    test "supports several interactions in one pact", %{pact: pact, tmp_dir: dir} do
      a = simple("first", "/first")

      b =
        HTTP.interaction("second")
        |> HTTP.with_request(:post, "/second")
        |> HTTP.will_respond_with(202)

      assert :ok =
               Consumer.run(pact, [a, b], fn m ->
                 assert %{status: 200} = Req.get!(m.url <> "/first")
                 assert %{status: 202} = Req.post!(m.url <> "/second")
               end)

      assert ["first", "second"] ==
               read_pact(dir)["interactions"] |> Enum.map(& &1["description"]) |> Enum.sort()
    end

    test "run twice merges the interactions into the same pact file", %{pact: pact, tmp_dir: dir} do
      a = simple("merge a", "/a")
      b = simple("merge b", "/b")

      assert :ok = Consumer.run(pact, [a], fn m -> Req.get!(m.url <> "/a") end)
      assert :ok = Consumer.run(pact, [b], fn m -> Req.get!(m.url <> "/b") end)

      assert ["merge a", "merge b"] ==
               read_pact(dir)["interactions"] |> Enum.map(& &1["description"]) |> Enum.sort()
    end
  end

  describe "run/4 interaction encoding, end to end" do
    test "request and response headers, status and query are written to the pact", %{
      pact: pact,
      tmp_dir: dir
    } do
      i =
        HTTP.interaction("headers")
        |> HTTP.with_request(:get, "/h",
          query: %{"page" => "2", "tag" => ["a", "b"]},
          headers: %{"x-req" => ["one", "two"]}
        )
        |> HTTP.will_respond_with(204, headers: %{"x-reply" => "yes"})

      assert :ok =
               Consumer.run(pact, [i], fn m ->
                 resp =
                   Req.get!(m.url <> "/h?page=2&tag=a&tag=b",
                     headers: [{"x-req", "one"}, {"x-req", "two"}]
                   )

                 assert resp.status == 204
                 assert Req.Response.get_header(resp, "x-reply") == ["yes"]
               end)

      [written] = read_pact(dir)["interactions"]
      assert written["response"]["status"] == 204
      assert written["response"]["headers"]["x-reply"] == ["yes"]
      assert written["request"]["query"]["tag"] == ["a", "b"]
      assert written["request"]["query"]["page"] == ["2"]
      assert written["request"]["headers"]["x-req"] == ["one", "two"]
    end

    test "atom query and header names are turned into strings", %{pact: pact, tmp_dir: dir} do
      i =
        HTTP.interaction("atom names")
        |> HTTP.with_request(:get, "/atoms", query: %{page: "1"}, headers: %{accept: "json"})
        |> HTTP.will_respond_with(200, headers: %{etag: "abc"})

      assert :ok =
               Consumer.run(pact, [i], fn m ->
                 resp = Req.get!(m.url <> "/atoms?page=1", headers: [{"accept", "json"}])
                 assert Req.Response.get_header(resp, "etag") == ["abc"]
               end)

      [written] = read_pact(dir)["interactions"]
      assert written["request"]["query"] == %{"page" => ["1"]}
      assert written["request"]["headers"]["accept"] == ["json"]
      assert written["response"]["headers"]["etag"] == ["abc"]
    end

    test "integer, float and boolean query and header values are stringified", %{
      pact: pact,
      tmp_dir: dir
    } do
      i =
        HTTP.interaction("scalars")
        |> HTTP.with_request(:get, "/scalars",
          query: %{"page" => 2, "ratio" => 1.5, "full" => true, "ids" => [1, 2]},
          headers: %{"x-n" => 5, "x-flag" => false}
        )
        |> HTTP.will_respond_with(200, headers: %{"x-count" => 3})

      assert :ok =
               Consumer.run(pact, [i], fn m ->
                 resp =
                   Req.get!(m.url <> "/scalars?page=2&ratio=1.5&full=true&ids=1&ids=2",
                     headers: [{"x-n", "5"}, {"x-flag", "false"}]
                   )

                 assert Req.Response.get_header(resp, "x-count") == ["3"]
               end)

      [written] = read_pact(dir)["interactions"]

      assert %{"page" => ["2"], "ratio" => ["1.5"], "full" => ["true"], "ids" => ["1", "2"]} =
               written["request"]["query"]

      assert %{"x-n" => ["5"], "x-flag" => ["false"]} = written["request"]["headers"]
    end

    test "matcher values in query and response headers are written as matching rules", %{
      pact: pact,
      tmp_dir: dir
    } do
      i =
        HTTP.interaction("matcher values")
        |> HTTP.with_request(:get, "/m",
          query: %{"id" => regex("12", "^\\d+$")},
          headers: %{"x-req" => regex("r-1", "^r-\\d+$")}
        )
        |> HTTP.will_respond_with(200, headers: %{"x-trace" => like("abc")})

      assert :ok =
               Consumer.run(pact, [i], fn m ->
                 resp = Req.get!(m.url <> "/m?id=777", headers: [{"x-req", "r-9"}])
                 assert Req.Response.get_header(resp, "x-trace") == ["abc"]
               end)

      [written] = read_pact(dir)["interactions"]
      assert get_in(written, ["request", "matchingRules", "query", "id"])
      assert get_in(written, ["request", "matchingRules", "header", "x-req"])
      assert get_in(written, ["response", "matchingRules", "header", "x-trace"])
    end

    test "a matcher path matches a different concrete path", %{pact: pact, tmp_dir: dir} do
      i =
        HTTP.interaction("matcher path")
        |> HTTP.with_request(:get, regex("/users/1", "^/users/\\d+$"))
        |> HTTP.will_respond_with(200)

      assert :ok = Consumer.run(pact, [i], fn m -> Req.get!(m.url <> "/users/99") end)

      [written] = read_pact(dir)["interactions"]
      assert written["request"]["path"] == "/users/1"
      assert get_in(written, ["request", "matchingRules", "path"])
    end

    test "provider states keep their order, with and without params", %{pact: pact, tmp_dir: dir} do
      i =
        HTTP.interaction("states")
        |> HTTP.given("first")
        |> HTTP.given("second", %{"n" => 2})
        |> HTTP.with_request(:get, "/states")
        |> HTTP.will_respond_with(200)

      assert :ok = Consumer.run(pact, [i], fn m -> Req.get!(m.url <> "/states") end)

      [written] = read_pact(dir)["interactions"]

      assert [%{"name" => "first"} = first, %{"name" => "second", "params" => %{"n" => 2}}] =
               written["providerStates"]

      refute Map.has_key?(first, "params")
    end

    test "a missing response defaults to status 200", %{pact: pact, tmp_dir: dir} do
      i = HTTP.interaction("no response") |> HTTP.with_request(:get, "/default")

      assert :ok =
               Consumer.run(pact, [i], fn m ->
                 assert %{status: 200} = Req.get!(m.url <> "/default")
               end)

      [written] = read_pact(dir)["interactions"]
      assert written["response"]["status"] == 200
    end

    test "a string body takes its content type from the Content-Type header", %{
      pact: pact,
      tmp_dir: dir
    } do
      json = ~s({"a":1})

      i =
        HTTP.interaction("string body with header")
        |> HTTP.with_request(:post, "/s",
          headers: %{"content-type" => "application/json"},
          body: json
        )
        |> HTTP.will_respond_with(200,
          headers: %{"Content-Type" => "application/vnd.test+json"},
          body: json
        )

      assert :ok =
               Consumer.run(pact, [i], fn m ->
                 resp = Req.post!(m.url <> "/s", json: %{a: 1}, retry: false)
                 assert resp.status == 200
                 assert resp.body == %{"a" => 1}
               end)

      [written] = read_pact(dir)["interactions"]
      assert written["request"]["body"]["contentType"] == "application/json"
      assert written["response"]["body"]["contentType"] == "application/vnd.test+json"
    end

    test "the header lookup ignores case and accepts atom names", %{pact: pact, tmp_dir: dir} do
      i =
        HTTP.interaction("atom content type")
        |> HTTP.with_request(:get, "/c")
        |> HTTP.will_respond_with(200,
          headers: %{"CONTENT-TYPE": "application/xml"},
          body: "<a/>"
        )

      assert :ok =
               Consumer.run(pact, [i], fn m -> Req.get!(m.url <> "/c", decode_body: false) end)

      assert body_of(dir, "response")["contentType"] == "application/xml"
    end

    test "an explicit content_type wins over the Content-Type header", %{
      pact: pact,
      tmp_dir: dir
    } do
      i =
        HTTP.interaction("explicit content type")
        |> HTTP.with_request(:get, "/e")
        |> HTTP.will_respond_with(200,
          headers: %{"Content-Type" => "application/json"},
          body: "<a/>",
          content_type: "application/xml"
        )

      assert :ok =
               Consumer.run(pact, [i], fn m -> Req.get!(m.url <> "/e", decode_body: false) end)

      assert body_of(dir, "response")["contentType"] == "application/xml"
    end

    test "a string body without a Content-Type header is text/plain", %{pact: pact, tmp_dir: dir} do
      i =
        HTTP.interaction("no content type")
        |> HTTP.with_request(:get, "/n")
        |> HTTP.will_respond_with(200, headers: %{"x-other" => "1"}, body: "hi")

      assert :ok =
               Consumer.run(pact, [i], fn m -> Req.get!(m.url <> "/n", decode_body: false) end)

      assert body_of(dir, "response")["contentType"] == "text/plain"
    end

    test "a matcher Content-Type header gives the body content type through its value", %{
      pact: pact,
      tmp_dir: dir
    } do
      i =
        HTTP.interaction("matcher content type")
        |> HTTP.with_request(:get, "/m2")
        |> HTTP.will_respond_with(200,
          headers: %{"Content-Type" => regex("application/json", "application/.+")},
          body: ~s({"a":1})
        )

      assert :ok =
               Consumer.run(pact, [i], fn m -> Req.get!(m.url <> "/m2", decode_body: false) end)

      assert body_of(dir, "response")["contentType"] == "application/json"
    end

    test "map bodies default to application/json", %{pact: pact, tmp_dir: dir} do
      i =
        HTTP.interaction("json defaults")
        |> HTTP.with_request(:post, "/json", body: %{"a" => 1})
        |> HTTP.will_respond_with(200, body: [1, 2, 3])

      assert :ok =
               Consumer.run(pact, [i], fn m ->
                 resp = Req.post!(m.url <> "/json", json: %{a: 1}, decode_body: false)
                 assert resp.body == "[1,2,3]"

                 assert Req.Response.get_header(resp, "content-type") |> hd() =~
                          "application/json"
               end)

      [written] = read_pact(dir)["interactions"]
      assert written["request"]["body"]["content"] == %{"a" => 1}
      assert written["response"]["body"]["content"] == [1, 2, 3]
    end

    test "string bodies default to text/plain", %{pact: pact} do
      i =
        HTTP.interaction("text defaults")
        |> HTTP.with_request(:get, "/text")
        |> HTTP.will_respond_with(200, body: "hello")

      assert :ok =
               Consumer.run(pact, [i], fn m ->
                 resp = Req.get!(m.url <> "/text", decode_body: false)
                 assert resp.body == "hello"
                 assert Req.Response.get_header(resp, "content-type") |> hd() =~ "text/plain"
               end)
    end

    test "a raw text request body is matched byte for byte", %{pact: pact, tmp_dir: dir} do
      xml = "<user><name>Ann</name></user>"

      i =
        HTTP.interaction("xml request")
        |> HTTP.with_request(:post, "/xml", body: xml, content_type: "application/xml")
        |> HTTP.will_respond_with(200)

      assert :ok =
               Consumer.run(pact, [i], fn m ->
                 Req.post!(m.url <> "/xml",
                   body: xml,
                   headers: [{"content-type", "application/xml"}]
                 )
               end)

      assert %{"content" => ^xml, "contentType" => "application/xml", "encoded" => false} =
               body_of(dir, "request")
    end

    test "a non-UTF-8 binary body goes through unchanged, in both directions", %{
      pact: pact,
      tmp_dir: dir
    } do
      payload = <<0, 255, 1, 128>>

      i =
        HTTP.interaction("binary")
        |> HTTP.with_request(:post, "/bin", body: payload)
        |> HTTP.will_respond_with(200, body: <<9, 200, 0>>, content_type: "image/png")

      assert :ok =
               Consumer.run(pact, [i], fn m ->
                 resp =
                   Req.post!(m.url <> "/bin",
                     body: payload,
                     headers: [{"content-type", "application/octet-stream"}],
                     decode_body: false
                   )

                 assert resp.body == <<9, 200, 0>>
                 assert Req.Response.get_header(resp, "content-type") |> hd() =~ "image/png"
               end)

      [written] = read_pact(dir)["interactions"]

      assert %{"content" => "CcgA", "contentType" => "image/png", "encoded" => "base64"} =
               written["response"]["body"]

      assert %{
               "content" => "AP8BgA==",
               "contentType" => "application/octet-stream",
               "encoded" => "base64"
             } = written["request"]["body"]
    end

    test "a UTF-8 body containing a NUL byte is sent as binary", %{pact: pact, tmp_dir: dir} do
      body = "a\0b"

      i =
        HTTP.interaction("nul body")
        |> HTTP.with_request(:get, "/nul")
        |> HTTP.will_respond_with(200, body: body)

      assert :ok =
               Consumer.run(pact, [i], fn m ->
                 resp = Req.get!(m.url <> "/nul", decode_body: false)
                 assert resp.body == body

                 assert Req.Response.get_header(resp, "content-type") |> hd() =~
                          "application/octet-stream"
               end)

      assert %{
               "content" => "YQBi",
               "contentType" => "application/octet-stream",
               "encoded" => "base64"
             } = body_of(dir, "response")
    end

    test "an each_like body is matched against a longer array", %{pact: pact, tmp_dir: dir} do
      i =
        HTTP.interaction("list")
        |> HTTP.with_request(:get, "/list")
        |> HTTP.will_respond_with(200, body: %{"items" => each_like(%{"id" => like(1)})})

      assert :ok =
               Consumer.run(pact, [i], fn m ->
                 assert %{body: %{"items" => [_ | _]}} = Req.get!(m.url <> "/list")
               end)

      [written] = read_pact(dir)["interactions"]
      assert get_in(written, ["response", "matchingRules", "body", "$.items"])
    end
  end

  describe "run/4 Content-Type handling" do
    defp content_type_entries(headers) do
      for {name, values} <- headers, String.downcase(name) == "content-type", do: {name, values}
    end

    # The JSON that pact_ffi turns into `<root><name>text</name></root>`. A
    # description of any other shape makes pact_ffi panic, which aborts the VM.
    defp xml_description(name, text) do
      %{
        "root" => %{
          "name" => "root",
          "children" => [%{"name" => name, "children" => [%{"content" => text}]}]
        }
      }
    end

    defp served_content_type(resp), do: Req.Response.get_header(resp, "content-type")

    test "a lowercase header with a map body leaves one Content-Type, in the pact and on the wire",
         %{pact: pact, tmp_dir: dir} do
      i =
        HTTP.interaction("lowercase header, map body")
        |> HTTP.with_request(:post, "/hal",
          headers: %{"content-type" => "application/hal+json"},
          body: %{"a" => 1}
        )
        |> HTTP.will_respond_with(200,
          headers: %{"content-type" => "application/hal+json"},
          body: %{"x" => like(1)}
        )

      assert :ok =
               Consumer.run(pact, [i], fn m ->
                 resp =
                   Req.post!(m.url <> "/hal",
                     body: ~s({"a":1}),
                     headers: [{"content-type", "application/hal+json"}],
                     decode_body: false,
                     retry: false
                   )

                 assert resp.status == 200
                 assert served_content_type(resp) == ["application/hal+json"]
               end)

      [written] = read_pact(dir)["interactions"]

      for part <- ["request", "response"] do
        assert [{"Content-Type", ["application/hal+json"]}] =
                 content_type_entries(written[part]["headers"])

        assert written[part]["body"]["contentType"] == "application/hal+json"
      end

      assert written["response"]["body"]["content"] == %{"x" => 1}
    end

    test "a lowercase header with a string body leaves one Content-Type", %{
      pact: pact,
      tmp_dir: dir
    } do
      json = ~s({"a":1})

      i =
        HTTP.interaction("lowercase header, string body")
        |> HTTP.with_request(:post, "/s",
          headers: %{"content-type" => "application/json"},
          body: json
        )
        |> HTTP.will_respond_with(200,
          headers: %{"content-type" => "application/vnd.test+json"},
          body: json
        )

      assert :ok =
               Consumer.run(pact, [i], fn m ->
                 resp =
                   Req.post!(m.url <> "/s",
                     body: json,
                     headers: [{"content-type", "application/json"}],
                     decode_body: false,
                     retry: false
                   )

                 assert served_content_type(resp) == ["application/vnd.test+json"]
                 assert resp.body == json
               end)

      [written] = read_pact(dir)["interactions"]

      assert [{"Content-Type", ["application/json"]}] =
               content_type_entries(written["request"]["headers"])

      assert [{"Content-Type", ["application/vnd.test+json"]}] =
               content_type_entries(written["response"]["headers"])
    end

    test "an atom header name in any case is canonicalised too", %{pact: pact, tmp_dir: dir} do
      i =
        HTTP.interaction("atom header name")
        |> HTTP.with_request(:get, "/a")
        |> HTTP.will_respond_with(200,
          headers: %{"content-type": "application/json"},
          body: %{"a" => 1}
        )

      assert :ok =
               Consumer.run(pact, [i], fn m ->
                 resp = Req.get!(m.url <> "/a", decode_body: false, retry: false)
                 assert served_content_type(resp) == ["application/json"]
               end)

      [written] = read_pact(dir)["interactions"]

      assert [{"Content-Type", ["application/json"]}] =
               content_type_entries(written["response"]["headers"])
    end

    test "a Content-Type header without a body is written under the canonical name", %{
      pact: pact,
      tmp_dir: dir
    } do
      i =
        HTTP.interaction("header only")
        |> HTTP.with_request(:get, "/h")
        |> HTTP.will_respond_with(204, headers: %{"content-type" => "text/csv"})

      assert :ok =
               Consumer.run(pact, [i], fn m -> Req.get!(m.url <> "/h", decode_body: false) end)

      [written] = read_pact(dir)["interactions"]
      assert written["response"]["headers"] == %{"Content-Type" => ["text/csv"]}
    end

    test "a list-valued header uses its first element for a map body", %{
      pact: pact,
      tmp_dir: dir
    } do
      i =
        HTTP.interaction("list header")
        |> HTTP.with_request(:get, "/l")
        |> HTTP.will_respond_with(200,
          headers: %{"content-type" => ["application/hal+json", "extra"]},
          body: %{"a" => 1}
        )

      assert :ok =
               Consumer.run(pact, [i], fn m ->
                 Req.get!(m.url <> "/l", decode_body: false, retry: false)
               end)

      [written] = read_pact(dir)["interactions"]
      assert written["response"]["body"]["contentType"] == "application/hal+json"

      assert [{"Content-Type", ["application/hal+json", "extra"]}] =
               content_type_entries(written["response"]["headers"])
    end

    test "a non-UTF-8 body takes its content type from the header", %{pact: pact, tmp_dir: dir} do
      payload = <<0, 255, 1, 128>>

      i =
        HTTP.interaction("binary with header")
        |> HTTP.with_request(:get, "/b")
        |> HTTP.will_respond_with(200, headers: %{"content-type" => "image/png"}, body: payload)

      assert :ok =
               Consumer.run(pact, [i], fn m ->
                 resp = Req.get!(m.url <> "/b", decode_body: false, retry: false)
                 assert resp.body == payload
                 assert served_content_type(resp) == ["image/png"]
               end)

      [written] = read_pact(dir)["interactions"]
      assert %{"contentType" => "image/png", "encoded" => "base64"} = written["response"]["body"]

      assert [{"Content-Type", ["image/png"]}] =
               content_type_entries(written["response"]["headers"])
    end

    test "a matcher header gives the content type of a map body", %{pact: pact, tmp_dir: dir} do
      i =
        HTTP.interaction("matcher header, map body")
        |> HTTP.with_request(:get, "/mm")
        |> HTTP.will_respond_with(200,
          headers: %{"Content-Type" => regex("application/hal+json", "application/.*json")},
          body: %{"a" => 1}
        )

      assert :ok =
               Consumer.run(pact, [i], fn m ->
                 resp = Req.get!(m.url <> "/mm", decode_body: false, retry: false)
                 assert served_content_type(resp) == ["application/hal+json"]
               end)

      [written] = read_pact(dir)["interactions"]
      assert written["response"]["body"]["contentType"] == "application/hal+json"
      assert get_in(written, ["response", "matchingRules", "header", "Content-Type"])
    end

    test "a map body with an XML Content-Type is processed as an XML description", %{
      pact: pact,
      tmp_dir: dir
    } do
      i =
        HTTP.interaction("xml description")
        |> HTTP.with_request(:post, "/xml",
          headers: %{"Content-Type" => "application/xml"},
          body: xml_description("a", "b")
        )
        |> HTTP.will_respond_with(200,
          headers: %{"content-type" => "application/xml"},
          body: xml_description("name", "Ann")
        )

      assert :ok =
               Consumer.run(pact, [i], fn m ->
                 resp =
                   Req.post!(m.url <> "/xml",
                     body: ~s(<?xml version="1.0" encoding="UTF-8"?><root><a>b</a></root>),
                     headers: [{"content-type", "application/xml"}],
                     decode_body: false,
                     retry: false
                   )

                 assert resp.status == 200
                 assert served_content_type(resp) == ["application/xml"]
                 assert resp.body =~ "<root><name>Ann</name></root>"
               end)

      [written] = read_pact(dir)["interactions"]

      for part <- ["request", "response"] do
        assert written[part]["body"]["contentType"] == "application/xml"
        assert is_binary(written[part]["body"]["content"])
        assert written[part]["body"]["content"] =~ "<root>"

        assert [{"Content-Type", ["application/xml"]}] =
                 content_type_entries(written[part]["headers"])
      end
    end

    test "an explicit content_type sets the body type and keeps the header as given", %{
      pact: pact,
      tmp_dir: dir
    } do
      i =
        HTTP.interaction("explicit wins")
        |> HTTP.with_request(:get, "/w")
        |> HTTP.will_respond_with(200,
          headers: %{"content-type" => "application/json"},
          body: %{"a" => 1},
          content_type: "application/hal+json"
        )

      assert :ok =
               Consumer.run(pact, [i], fn m ->
                 resp = Req.get!(m.url <> "/w", decode_body: false, retry: false)
                 assert served_content_type(resp) == ["application/json"]
               end)

      [written] = read_pact(dir)["interactions"]
      assert written["response"]["body"]["contentType"] == "application/hal+json"

      assert [{"Content-Type", ["application/json"]}] =
               content_type_entries(written["response"]["headers"])
    end

    test "two Content-Type headers that differ only in case are rejected", %{pact: pact} do
      i =
        HTTP.interaction("duplicate content type")
        |> HTTP.with_request(:get, "/d")
        |> HTTP.will_respond_with(200,
          headers: %{"content-type" => "text/plain", "Content-Type" => "text/csv"}
        )

      assert {:error, %PactEx.Error{code: -101, message: message}} =
               Consumer.start_mock_server(pact, [i])

      assert message =~ "Content-Type"
    end
  end

  describe "run/4 invalid interactions" do
    test "an interaction without a request returns a PactEx.Error before any server starts", %{
      pact: pact,
      tmp_dir: dir
    } do
      i = HTTP.interaction("no request") |> HTTP.will_respond_with(200)
      parent = self()

      assert {:error, %PactEx.Error{message: message}} =
               Consumer.run(pact, [i], fn _ -> send(parent, :called) end)

      assert message =~ "no request"
      assert message =~ "with_request"
      refute_received :called
      refute File.exists?(pact_path(dir))
    end

    test "run!/4 raises PactEx.Error for an interaction without a request", %{pact: pact} do
      i = HTTP.interaction("no request")

      assert_raise PactEx.Error, ~r/with_request/, fn ->
        Consumer.run!(pact, [i], fn _ -> :ok end)
      end
    end

    test "unsupported value types are rejected with a PactEx.Error", %{pact: pact} do
      cases = [
        {"query", &HTTP.with_request(&1, :get, "/x", query: %{"page" => {:tuple}})},
        {"header", &HTTP.with_request(&1, :get, "/x", headers: %{"x" => self()})},
        {"body", &HTTP.with_request(&1, :get, "/x", body: 42)},
        {"response header",
         &(&1
           |> HTTP.with_request(:get, "/x")
           |> HTTP.will_respond_with(200, headers: %{"y" => {:tuple}}))}
      ]

      for {label, build} <- cases do
        i = build.(HTTP.interaction(label))

        assert {:error, %PactEx.Error{code: -101, function: function, message: message}} =
                 Consumer.start_mock_server(pact, [i])

        assert function == "PactEx.Consumer.start_mock_server/3"
        assert message =~ label
      end
    end

    test "nil query and header values are rejected, naming the key", %{pact: pact} do
      cases = [
        {~s("page"), &HTTP.with_request(&1, :get, "/x", query: %{"page" => nil})},
        {~s("x-n"), &HTTP.with_request(&1, :get, "/x", headers: %{"x-n" => nil})},
        {~s("tag"), &HTTP.with_request(&1, :get, "/x", query: %{"tag" => ["a", nil]})}
      ]

      for {key, build} <- cases do
        i = build.(HTTP.interaction("nil value"))

        assert {:error, %PactEx.Error{code: -101, message: message}} =
                 Consumer.start_mock_server(pact, [i])

        assert message =~ key
        assert message =~ "nil"
      end
    end

    test "non-string, non-atom query and header names are rejected, naming the key", %{pact: pact} do
      cases = [
        &HTTP.with_request(&1, :get, "/x", query: %{1 => "a"}),
        &HTTP.with_request(&1, :get, "/x", headers: %{{:a} => "a"}),
        &HTTP.with_request(&1, :get, "/x", query: %{nil => "a"}),
        &(&1
          |> HTTP.with_request(:get, "/x")
          |> HTTP.will_respond_with(200, headers: %{2 => "a"}))
      ]

      for build <- cases do
        i = build.(HTTP.interaction("bad name"))

        assert {:error, %PactEx.Error{code: -101, message: message}} =
                 Consumer.start_mock_server(pact, [i])

        assert message =~ "name"
      end
    end

    test "a body that cannot be encoded as JSON is rejected with a PactEx.Error", %{pact: pact} do
      i =
        HTTP.interaction("bad json")
        |> HTTP.with_request(:post, "/x", body: %{"a" => bad({:tuple})})

      assert {:error, %PactEx.Error{message: message}} = Consumer.start_mock_server(pact, [i])
      assert message =~ "JSON"
    end

    test "a NUL byte in a header, query name, content type or provider state is a PactEx.Error",
         %{
           pact: pact
         } do
      cases = [
        HTTP.interaction("a")
        |> HTTP.with_request(:get, "/x", headers: %{"x-a" => "v\0"}),
        HTTP.interaction("b")
        |> HTTP.with_request(:get, "/x", query: %{"q\0" => "v"}),
        HTTP.interaction("c")
        |> HTTP.with_request(:post, "/x", body: "hi", content_type: "text/\0plain"),
        HTTP.interaction("d")
        |> HTTP.with_request(:get, "/x")
        |> HTTP.will_respond_with(200, headers: %{"x-b" => "v\0"}),
        HTTP.interaction("e")
        |> HTTP.given("state\0")
        |> HTTP.with_request(:get, "/x")
      ]

      for i <- cases do
        assert {:error, %PactEx.Error{code: -100}} = Consumer.start_mock_server(pact, [i])
      end
    end
  end

  describe "run!/4" do
    test "raises MismatchError", %{pact: pact} do
      i = simple("never", "/never")
      assert_raise PactEx.MismatchError, fn -> Consumer.run!(pact, [i], fn _ -> :ok end) end
    end

    test "returns :ok when everything matched", %{pact: pact} do
      i = simple("ok", "/ok")
      assert :ok = Consumer.run!(pact, [i], fn m -> Req.get!(m.url <> "/ok") end)
    end

    test "raises PactEx.Error when the pact cannot be written", %{tmp_dir: dir} do
      blocker = Path.join(dir, "blocker")
      File.write!(blocker, "x")
      pact = PactEx.new("consumer-test", "provider-test", pact_dir: blocker)
      i = simple("unwritable", "/u")

      assert_raise PactEx.Error, fn ->
        Consumer.run!(pact, [i], fn m -> Req.get!(m.url <> "/u") end)
      end
    end

    test "re-raises exceptions from the test function", %{pact: pact} do
      i = simple("boom", "/boom")

      assert_raise RuntimeError, "boom", fn ->
        Consumer.run!(pact, [i], fn _ -> raise "boom" end)
      end
    end
  end

  test "the re-raised exception keeps its original stacktrace", %{pact: pact} do
    i = simple("trace", "/trace")

    {error, stacktrace} =
      try do
        Consumer.run(pact, [i], fn _ -> raise "from the test function" end)
      rescue
        e -> {e, __STACKTRACE__}
      end

    assert %RuntimeError{message: "from the test function"} = error
    {_module, _function, _arity, location} = hd(stacktrace)
    assert Path.basename(to_string(location[:file])) == "consumer_test.exs"
  end

  describe "start_mock_server/3" do
    test "low-level API: start, matched?, mismatches, write_pact, stop", %{
      pact: pact,
      tmp_dir: dir
    } do
      i = simple("low", "/low")

      assert {:ok, %PactEx.MockServer{port: port, url: url} = mock} =
               Consumer.start_mock_server(pact, [i])

      assert url == "http://127.0.0.1:#{port}"
      assert mock.pact_dir == dir
      assert is_reference(mock.pact_ref)
      refute PactEx.MockServer.matched?(mock)
      assert [%{"type" => "missing-request"}] = PactEx.MockServer.mismatches(mock)
      Req.get!(url <> "/low")
      assert PactEx.MockServer.matched?(mock)
      assert PactEx.MockServer.mismatches(mock) == []
      assert :ok = PactEx.MockServer.write_pact(mock)
      assert File.exists?(pact_path(dir))
      assert :ok = PactEx.MockServer.stop(mock)
      refute PactEx.Native.cleanup_mock_server(port)
    end

    test "uses an OS-assigned port by default and distinct ports for concurrent servers", %{
      pact: pact
    } do
      i = simple("ports", "/ports")
      {:ok, a} = Consumer.start_mock_server(pact, [i])
      {:ok, b} = Consumer.start_mock_server(pact, [i])
      on_exit(fn -> PactEx.MockServer.stop(a) end)
      on_exit(fn -> PactEx.MockServer.stop(b) end)
      assert a.port > 0
      assert a.port != b.port
    end

    test "accepts an explicit host and port", %{pact: pact} do
      {:ok, listener} = :gen_tcp.listen(0, [])
      {:ok, free_port} = :inet.port(listener)
      :gen_tcp.close(listener)

      i = simple("explicit", "/explicit")

      assert {:ok, mock} =
               Consumer.start_mock_server(pact, [i], host: "127.0.0.1", port: free_port)

      on_exit(fn -> PactEx.MockServer.stop(mock) end)
      assert mock.port == free_port
      assert mock.url == "http://127.0.0.1:#{free_port}"
      assert %{status: 200} = Req.get!(mock.url <> "/explicit")
    end

    test "binds an IPv6 loopback host and brackets it in the url", %{pact: pact} do
      case :gen_tcp.listen(0, [:inet6, ip: {0, 0, 0, 0, 0, 0, 0, 1}]) do
        {:ok, socket} ->
          :gen_tcp.close(socket)
          i = simple("ipv6", "/ipv6")
          assert {:ok, mock} = Consumer.start_mock_server(pact, [i], host: "::1")
          on_exit(fn -> PactEx.MockServer.stop(mock) end)
          assert mock.url == "http://[::1]:#{mock.port}"
          assert %{status: 200} = Req.get!(mock.url <> "/ipv6", retry: false)

        {:error, _reason} ->
          # No IPv6 loopback on this machine.
          :ok
      end
    end

    test "fails with a PactEx.Error when the port is already in use", %{pact: pact} do
      i = simple("busy", "/busy")
      {:ok, first} = Consumer.start_mock_server(pact, [i])
      on_exit(fn -> PactEx.MockServer.stop(first) end)

      assert {:error, %PactEx.Error{function: "pactffi_create_mock_server_for_transport"}} =
               Consumer.start_mock_server(pact, [i], port: first.port)
    end

    test "fails with a PactEx.Error when the host cannot be bound", %{pact: pact} do
      i = simple("badhost", "/badhost")

      assert {:error, %PactEx.Error{function: "pactffi_create_mock_server_for_transport"}} =
               Consumer.start_mock_server(pact, [i], host: "no such host")
    end

    test "rejects a port outside 0..65535 and unknown options", %{pact: pact} do
      i = simple("range", "/range")
      assert_raise ArgumentError, fn -> Consumer.start_mock_server(pact, [i], port: 70_000) end
      assert_raise ArgumentError, fn -> Consumer.start_mock_server(pact, [i], port: -1) end
      assert_raise ArgumentError, fn -> Consumer.start_mock_server(pact, [i], bad(hots: "x")) end
    end

    test "rejects a NUL byte in the consumer, provider or description", %{tmp_dir: dir} do
      i = simple("ok", "/ok")

      assert_raise ArgumentError, fn ->
        Consumer.start_mock_server(PactEx.new("c\0", "p", pact_dir: dir), [i])
      end

      assert_raise ArgumentError, fn ->
        Consumer.start_mock_server(PactEx.new("c", "p\0", pact_dir: dir), [i])
      end

      assert_raise ArgumentError, fn ->
        Consumer.start_mock_server(PactEx.new("c", "p", pact_dir: dir), [simple("d\0", "/ok")])
      end
    end

    test "invalid input surfaces as PactEx.Error from start_mock_server", %{pact: pact} do
      i =
        HTTP.interaction("bad")
        |> HTTP.with_request(:get, "/bad\0path")
        |> HTTP.will_respond_with(200)

      assert {:error, %PactEx.Error{code: -100}} = Consumer.start_mock_server(pact, [i])
    end

    test "returns a PactEx.Error for an interaction without a request", %{pact: pact} do
      i = HTTP.interaction("no request")
      assert {:error, %PactEx.Error{message: message}} = Consumer.start_mock_server(pact, [i])
      assert message =~ "no request"
    end

    test "rejects arguments of the wrong type", %{pact: pact} do
      assert_raise FunctionClauseError, fn -> Consumer.start_mock_server(bad(:pact), []) end

      assert_raise FunctionClauseError, fn ->
        Consumer.start_mock_server(pact, bad(:not_a_list))
      end
    end
  end

  test "PactEx.Error.from_native/1 builds the exception" do
    e = PactEx.Error.from_native(%{function: "pactffi_x", code: 2, message: "boom"})
    assert %PactEx.Error{function: "pactffi_x", code: 2, message: "boom"} = e
    assert Exception.message(e) =~ "boom"
  end
end
