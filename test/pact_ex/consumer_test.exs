defmodule PactEx.ConsumerTest do
  use ExUnit.Case, async: true
  import PactEx.Matchers
  alias PactEx.{Consumer, HTTP}

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    %{pact: PactEx.new("consumer-test", "provider-test", pact_dir: dir)}
  end

  defp bad(value), do: Function.identity(value)
  defp bad_improper, do: Function.identity([1 | 2])

  # Read-only check that no server is registered on `port`. A cleanup would
  # kill a concurrent test's server if the OS reused the port.
  defp assert_stopped(port) do
    assert PactEx.Native.mock_server_mismatches(port) == nil
    refute PactEx.Native.mock_server_matched(port)
  end

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
      # Read-only probe: never clean up a port this test no longer owns.
      assert_stopped(port)
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
      assert_stopped(port)

      assert {:shutdown, :bye} ==
               catch_exit(
                 Consumer.run(pact, [i], fn m ->
                   send(parent, {:port, m.port})
                   exit({:shutdown, :bye})
                 end)
               )

      assert_received {:port, port}
      assert_stopped(port)
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

    test "a regex matcher on a number and a boolean in a JSON body matches their string form",
         %{pact: pact, tmp_dir: dir} do
      i =
        HTTP.interaction("regex on non-strings")
        |> HTTP.with_request(:post, "/r",
          body: %{"n" => regex(42, "^\\d+$"), "ok" => regex(true, "^(true|false)$")}
        )
        |> HTTP.will_respond_with(200)

      assert :ok =
               Consumer.run(pact, [i], fn m ->
                 assert Req.post!(m.url <> "/r", json: %{"n" => 7, "ok" => false}).status == 200
               end)

      [written] = read_pact(dir)["interactions"]
      assert written["request"]["body"]["content"] == %{"n" => 42, "ok" => true}
      assert written["request"]["matchingRules"]["body"]["$.n"]["combine"] == "AND"

      rules = written["request"]["matchingRules"]["body"]

      assert [%{"match" => "regex", "regex" => "^\\d+$"}] = rules["$.n"]["matchers"]
      assert [%{"match" => "regex", "regex" => "^(true|false)$"}] = rules["$.ok"]["matchers"]

      # A value whose string form does not match the pattern is a mismatch.
      File.rm!(pact_path(dir))

      assert {:error, %PactEx.MismatchError{}} =
               Consumer.run(pact, [i], fn m ->
                 Req.post!(m.url <> "/r",
                   json: %{"n" => 7.5, "ok" => false},
                   retry: false,
                   http_errors: :return
                 )
               end)

      refute File.exists?(pact_path(dir))
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

    # The JSON that pact_ffi turns into `<root><name>text</name></root>`.
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

  describe "run/4 Content-Type header that resolves to an empty list" do
    # pactffi_with_body panics on these (pact_models indexes `v[0]` of the
    # header) and the panic aborts the VM, until they were rejected up front.
    # Binary and body-less parts did not abort, but are rejected as well.
    @empty_value %{"value" => []}

    @empty_headers [
      {"value", %{"Content-Type" => @empty_value}},
      {"matcher", %{"Content-Type" => %{"pact:matcher:type" => "type", "value" => []}}},
      {"json text", %{"Content-Type" => ~s({"value":[]})}},
      {"list form", %{"Content-Type" => [@empty_value]}},
      {"last of a list", %{"Content-Type" => ["text/plain", @empty_value]}},
      {"first of a list", %{"Content-Type" => [@empty_value, "text/plain"]}},
      {"middle of a list", %{"Content-Type" => ["text/csv", @empty_value, "text/plain"]}},
      {"lowercase name", %{"content-type" => @empty_value}},
      {"atom name", %{"Content-Type": @empty_value}}
    ]

    @empty_bodies [
      {"map body", [body: %{"a" => 1}]},
      {"explicit type and map body", [body: %{"a" => 1}, content_type: "application/json"]},
      {"string body", [body: "hello"]},
      {"empty string body", [body: ""]},
      {"binary body", [body: <<255, 0, 1>>]},
      {"no body", []}
    ]

    test "every shape is rejected on the response side, before any server starts", %{
      pact: pact,
      tmp_dir: dir
    } do
      for {hn, headers} <- @empty_headers, {bn, opts} <- @empty_bodies do
        i =
          HTTP.interaction("empty content type")
          |> HTTP.with_request(:get, "/e")
          |> HTTP.will_respond_with(200, [headers: headers] ++ opts)

        assert {:error, %PactEx.Error{code: -101, function: function, message: message}} =
                 Consumer.start_mock_server(pact, [i]),
               "#{hn}, #{bn}"

        assert function == "PactEx.Consumer.start_mock_server/3"
        assert message =~ "response header"
        assert message =~ "empty content type"
      end

      refute File.exists?(pact_path(dir))
    end

    test "every shape is rejected on the request side", %{pact: pact, tmp_dir: dir} do
      for {hn, headers} <- @empty_headers, {bn, opts} <- @empty_bodies do
        i =
          HTTP.interaction("empty request content type")
          |> HTTP.with_request(:post, "/e", [headers: headers] ++ opts)
          |> HTTP.will_respond_with(200)

        assert {:error, %PactEx.Error{code: -101, message: message}} =
                 Consumer.start_mock_server(pact, [i]),
               "#{hn}, #{bn}"

        assert message =~ "request header"
      end

      refute File.exists?(pact_path(dir))
    end

    test "an empty element before a value is rejected on request and response", %{pact: pact} do
      headers = %{"Content-Type" => [@empty_value, "text/plain"]}

      request_side =
        HTTP.interaction("partly empty request")
        |> HTTP.with_request(:post, "/p", headers: headers, body: "x")
        |> HTTP.will_respond_with(200)

      response_side =
        HTTP.interaction("partly empty response")
        |> HTTP.with_request(:get, "/p")
        |> HTTP.will_respond_with(200, headers: headers, body: "x")

      assert {:error, %PactEx.Error{code: -101, message: request_message}} =
               Consumer.start_mock_server(pact, [request_side])

      assert request_message =~ "request header"
      assert request_message =~ "element 0"

      assert {:error, %PactEx.Error{code: -101, message: response_message}} =
               Consumer.start_mock_server(pact, [response_side])

      assert response_message =~ "response header"
      assert response_message =~ "element 0"
    end

    test "run/3 returns the error without calling the function and writes no pact", %{
      pact: pact,
      tmp_dir: dir
    } do
      i =
        HTTP.interaction("empty content type")
        |> HTTP.with_request(:get, "/e")
        |> HTTP.will_respond_with(200,
          headers: %{"Content-Type" => @empty_value},
          body: %{"a" => 1}
        )

      parent = self()

      assert {:error, %PactEx.Error{code: -101}} =
               Consumer.run(pact, [i], fn _ -> send(parent, :called) end)

      refute_received :called
      refute File.exists?(pact_path(dir))
    end

    test "an invalid interaction after a good one stops everything before any server starts", %{
      pact: pact
    } do
      bad =
        HTTP.interaction("empty content type")
        |> HTTP.with_request(:get, "/e")
        |> HTTP.will_respond_with(200, headers: %{"Content-Type" => @empty_value}, body: "x")

      assert {:error, %PactEx.Error{code: -101}} =
               Consumer.start_mock_server(pact, [simple("good", "/good"), bad])
    end

    test "a normal Content-Type is still served and recorded", %{pact: pact, tmp_dir: dir} do
      i =
        HTTP.interaction("normal content type")
        |> HTTP.with_request(:post, "/n",
          headers: %{"Content-Type" => "application/json"},
          body: %{"in" => 1}
        )
        |> HTTP.will_respond_with(200,
          headers: %{"Content-Type" => "application/json"},
          body: %{"out" => 2}
        )

      assert :ok =
               Consumer.run(pact, [i], fn m ->
                 resp = Req.post!(m.url <> "/n", json: %{in: 1}, decode_body: false)
                 assert resp.body == ~s({"out":2})
                 assert Req.Response.get_header(resp, "content-type") == ["application/json"]
               end)

      [written] = read_pact(dir)["interactions"]
      assert written["request"]["headers"] == %{"Content-Type" => ["application/json"]}
      assert written["response"]["headers"] == %{"Content-Type" => ["application/json"]}
      assert written["response"]["body"]["content"] == %{"out" => 2}
    end

    test "a non-empty array value and a matcher with a string value are still accepted", %{
      pact: pact,
      tmp_dir: dir
    } do
      array =
        HTTP.interaction("array content type")
        |> HTTP.with_request(:get, "/a")
        |> HTTP.will_respond_with(200,
          headers: %{"Content-Type" => %{"value" => ["application/json"]}},
          body: %{"a" => 1}
        )

      matcher =
        HTTP.interaction("matcher content type")
        |> HTTP.with_request(:get, "/m")
        |> HTTP.will_respond_with(200,
          headers: %{"Content-Type" => regex("application/json", "application/.+")},
          body: %{"m" => 1}
        )

      assert :ok =
               Consumer.run(pact, [array, matcher], fn m ->
                 for path <- ["/a", "/m"] do
                   resp = Req.get!(m.url <> path, decode_body: false, retry: false)
                   assert resp.status == 200
                   assert Req.Response.get_header(resp, "content-type") == ["application/json"]
                 end
               end)

      interactions = read_pact(dir)["interactions"]
      assert length(interactions) == 2

      for written <- interactions do
        assert written["response"]["headers"]["Content-Type"] == ["application/json"]
      end
    end

    test "the same value on another header is not touched", %{pact: pact, tmp_dir: dir} do
      i =
        HTTP.interaction("other header")
        |> HTTP.with_request(:get, "/o")
        |> HTTP.will_respond_with(200, headers: %{"X-Other" => @empty_value}, body: %{"a" => 1})

      assert :ok =
               Consumer.run(pact, [i], fn m ->
                 assert %{status: 200} = Req.get!(m.url <> "/o", decode_body: false)
               end)

      [written] = read_pact(dir)["interactions"]
      assert written["response"]["headers"]["X-Other"] == []
    end
  end

  describe "run/4 keyword lists and lists of pairs for headers and query" do
    test "keyword query and headers with repeated keys match a real request and are recorded",
         %{pact: pact, tmp_dir: dir} do
      i =
        HTTP.interaction("keyword lists")
        |> HTTP.with_request(:get, "/k",
          query: [tag: "a", page: 2, tag: "b", active: true],
          headers: [{"X-Trace", "1"}, accept: "application/json", x_multi: "m1", x_multi: "m2"]
        )
        |> HTTP.will_respond_with(200,
          headers: [{"x-out", "o1"}, {"X-Out", "o2"}, etag: "abc"],
          body: %{"ok" => true}
        )

      assert :ok =
               Consumer.run(pact, [i], fn m ->
                 # Req's own keyword form: it turns `x_multi` into `x-multi`.
                 resp =
                   Req.get!(m.url <> "/k?tag=a&page=2&tag=b&active=true",
                     headers: [
                       {"X-Trace", "1"},
                       accept: "application/json",
                       x_multi: "m1",
                       x_multi: "m2"
                     ],
                     retry: false
                   )

                 assert resp.status == 200
                 assert resp.body == %{"ok" => true}
                 assert Req.Response.get_header(resp, "x-out") == ["o1", "o2"]
                 assert Req.Response.get_header(resp, "etag") == ["abc"]
               end)

      [written] = read_pact(dir)["interactions"]

      assert written["request"]["query"] == %{
               "tag" => ["a", "b"],
               "page" => ["2"],
               "active" => ["true"]
             }

      assert written["request"]["headers"]["X-Trace"] == ["1"]
      assert written["request"]["headers"]["accept"] == ["application/json"]
      assert written["request"]["headers"]["x-multi"] == ["m1", "m2"]
      assert written["response"]["headers"]["x-out"] == ["o1", "o2"]
      assert written["response"]["headers"]["etag"] == ["abc"]
    end

    test "atom header names are dashed like Req does, in a map and in a list", %{
      pact: pact,
      tmp_dir: dir
    } do
      i =
        HTTP.interaction("atom headers")
        |> HTTP.with_request(:post, "/a",
          headers: %{"x_kept" => "k", content_type: "application/json", x_request_id: "1"},
          body: %{"a" => 1}
        )
        |> HTTP.will_respond_with(200,
          headers: [x_out_id: "o", content_type: "text/plain"],
          body: "ok"
        )

      assert :ok =
               Consumer.run(pact, [i], fn m ->
                 resp =
                   Req.post!(m.url <> "/a",
                     json: %{a: 1},
                     headers: [{"x_kept", "k"}, x_request_id: "1"],
                     decode_body: false,
                     retry: false
                   )

                 assert resp.status == 200
                 assert Req.Response.get_header(resp, "x-out-id") == ["o"]
                 assert Req.Response.get_header(resp, "content-type") == ["text/plain"]
               end)

      [written] = read_pact(dir)["interactions"]
      assert written["request"]["headers"]["Content-Type"] == ["application/json"]
      assert written["request"]["headers"]["x-request-id"] == ["1"]
      assert written["request"]["headers"]["x_kept"] == ["k"]

      assert Map.keys(written["request"]["headers"]) |> Enum.sort() ==
               ["Content-Type", "x-request-id", "x_kept"]

      assert written["response"]["headers"]["x-out-id"] == ["o"]
      assert written["response"]["headers"]["Content-Type"] == ["text/plain"]
    end

    test "an atom header name with an underscore canonicalises Content-Type", %{pact: pact} do
      for headers <- [%{content_type: "text/plain"}, [content_type: "text/plain"]] do
        i =
          HTTP.interaction("content_type atom")
          |> HTTP.with_request(:post, "/ct", headers: headers, body: "hi")
          |> HTTP.will_respond_with(200)

        assert :ok =
                 Consumer.run(pact, [i], fn m ->
                   assert %{status: 200} =
                            Req.post!(m.url <> "/ct",
                              body: "hi",
                              headers: [content_type: "text/plain"],
                              retry: false
                            )
                 end)
      end
    end

    test "the same interaction with maps gives the same pact file", %{pact: pact, tmp_dir: dir} do
      kw =
        HTTP.interaction("same")
        |> HTTP.with_request(:get, "/s", query: [tag: "a", tag: "b"], headers: [{"x-id", "1"}])
        |> HTTP.will_respond_with(200, headers: [{"x-out", "a"}, {"x-out", "b"}])

      map =
        HTTP.interaction("same")
        |> HTTP.with_request(:get, "/s", query: %{"tag" => ["a", "b"]}, headers: %{"x-id" => "1"})
        |> HTTP.will_respond_with(200, headers: %{"x-out" => ["a", "b"]})

      map_dir = Path.join(dir, "map")
      map_pact = PactEx.new("consumer-test", "provider-test", pact_dir: map_dir)

      call = fn m ->
        assert %{status: 200} =
                 Req.get!(m.url <> "/s?tag=a&tag=b", headers: [{"x-id", "1"}], retry: false)
      end

      assert :ok = Consumer.run(pact, [kw], call)
      assert :ok = Consumer.run(map_pact, [map], call)

      assert read_pact(dir)["interactions"] == read_pact(map_dir)["interactions"]
    end

    test "a nil value in a list is rejected like in a map", %{pact: pact, tmp_dir: dir} do
      i =
        HTTP.interaction("nil in a keyword list")
        |> HTTP.with_request(:get, "/n", query: [tag: nil])
        |> HTTP.will_respond_with(200)

      assert {:error, %PactEx.Error{code: -101}} = Consumer.start_mock_server(pact, [i])
      refute File.exists?(pact_path(dir))
    end

    test "an empty list value in a keyword list is rejected, naming the key", %{pact: pact} do
      i =
        HTTP.interaction("empty in a keyword list")
        |> HTTP.with_request(:get, "/n", query: [tag: []])
        |> HTTP.will_respond_with(200)

      assert {:error, %PactEx.Error{code: -101, message: message}} =
               Consumer.start_mock_server(pact, [i])

      assert message =~ ~s("tag")
    end
  end

  describe "run/4 empty Content-Type values and empty lists of values" do
    # pact_ffi records an empty or blank Content-Type as an empty string. On a
    # request no client sends it, so no request can match it (the mock server
    # answers 500). On a response the mock server would serve a meaningless
    # header that no provider can produce. A `[]` value for a header or query
    # parameter wrote nothing and was dropped.
    @blank_headers [
      {"empty string", %{"Content-Type" => ""}},
      {"blank string", %{"Content-Type" => "  "}},
      {"empty first element", %{"Content-Type" => ["", "text/plain"]}},
      {"empty last element", %{"Content-Type" => ["text/plain", ""]}},
      {"matcher with an empty string", %{"Content-Type" => %{"value" => ""}}},
      {"json text with a blank string", %{"Content-Type" => ~s({"value":" "})}},
      {"lowercase name", %{"content-type" => ""}}
    ]

    test "an empty or blank Content-Type is rejected on request and response", %{
      pact: pact,
      tmp_dir: dir
    } do
      for {hn, headers} <- @blank_headers, body <- [nil, %{"a" => 1}, "text"] do
        request =
          HTTP.interaction("blank content type")
          |> HTTP.with_request(:post, "/b", headers: headers, body: body)
          |> HTTP.will_respond_with(200)

        response =
          HTTP.interaction("blank content type")
          |> HTTP.with_request(:get, "/b")
          |> HTTP.will_respond_with(200, headers: headers, body: body)

        assert {:error, %PactEx.Error{code: -101, function: function, message: message}} =
                 Consumer.start_mock_server(pact, [request]),
               "#{hn}, request, #{inspect(body)}"

        assert function == "PactEx.Consumer.start_mock_server/3"
        assert message =~ "request header"
        assert message =~ "empty or only whitespace"

        assert {:error, %PactEx.Error{code: -101, message: message}} =
                 Consumer.start_mock_server(pact, [response]),
               "#{hn}, response, #{inspect(body)}"

        assert message =~ "response header"
      end

      refute File.exists?(pact_path(dir))
    end

    test "run/3 with a blank Content-Type does not call the function and writes no pact", %{
      pact: pact,
      tmp_dir: dir
    } do
      i =
        HTTP.interaction("blank content type")
        |> HTTP.with_request(:post, "/b", headers: %{"Content-Type" => ["", "text/plain"]})
        |> HTTP.will_respond_with(200)

      parent = self()

      assert {:error, %PactEx.Error{code: -101}} =
               Consumer.run(pact, [i], fn _ -> send(parent, :called) end)

      refute_received :called
      refute File.exists?(pact_path(dir))
    end

    test "a request header of [] is rejected, naming the header", %{pact: pact, tmp_dir: dir} do
      for {name, shown} <- [{"x-id", "x-id"}, {:x_id, "x-id"}, {"Content-Type", "Content-Type"}] do
        i =
          HTTP.interaction("empty request header")
          |> HTTP.with_request(:get, "/h", headers: %{name => []})
          |> HTTP.will_respond_with(200)

        assert {:error, %PactEx.Error{code: -101, function: function, message: message}} =
                 Consumer.start_mock_server(pact, [i]),
               inspect(name)

        assert function == "PactEx.Consumer.start_mock_server/3"
        assert message =~ "request header"
        assert message =~ ~s("#{shown}")
        assert message =~ "empty list"
      end

      refute File.exists?(pact_path(dir))
    end

    test "a response header of [] is rejected, naming the header", %{pact: pact, tmp_dir: dir} do
      i =
        HTTP.interaction("empty response header")
        |> HTTP.with_request(:get, "/h")
        |> HTTP.will_respond_with(200, headers: %{"x-out" => []})

      assert {:error, %PactEx.Error{code: -101, message: message}} =
               Consumer.start_mock_server(pact, [i])

      assert message =~ "response header"
      assert message =~ ~s("x-out")
      refute File.exists?(pact_path(dir))
    end

    test "a query parameter of [] is rejected, naming the parameter", %{pact: pact, tmp_dir: dir} do
      for name <- ["tag", :tag] do
        i =
          HTTP.interaction("empty query")
          |> HTTP.with_request(:get, "/q", query: %{"ok" => "1", name => []})
          |> HTTP.will_respond_with(200)

        assert {:error, %PactEx.Error{code: -101, message: message}} =
                 Consumer.start_mock_server(pact, [i]),
               inspect(name)

        assert message =~ "request query parameter"
        assert message =~ ~s("tag")
      end

      parent = self()

      i =
        HTTP.interaction("empty query")
        |> HTTP.with_request(:get, "/q", query: %{"tag" => []})
        |> HTTP.will_respond_with(200)

      assert {:error, %PactEx.Error{code: -101}} =
               Consumer.run(pact, [i], fn _ -> send(parent, :called) end)

      refute_received :called
      refute File.exists?(pact_path(dir))
    end

    test "a bad interaction after a good one returns -101", %{
      pact: pact
    } do
      bad =
        HTTP.interaction("empty query")
        |> HTTP.with_request(:get, "/q", query: %{"tag" => []})
        |> HTTP.will_respond_with(200)

      assert {:error, %PactEx.Error{code: -101}} =
               Consumer.start_mock_server(pact, [simple("good", "/good"), bad])
    end

    test "non-empty lists and a non-blank Content-Type are still served and recorded", %{
      pact: pact,
      tmp_dir: dir
    } do
      i =
        HTTP.interaction("lists")
        |> HTTP.with_request(:get, "/l",
          query: %{"tag" => ["a", "b"]},
          headers: %{"x-id" => ["1"], "Content-Type" => ["text/plain"]}
        )
        |> HTTP.will_respond_with(200, headers: %{"x-out" => ["a", "b"]})

      assert :ok =
               Consumer.run(pact, [i], fn m ->
                 assert %{status: 200} =
                          Req.get!(m.url <> "/l?tag=a&tag=b",
                            headers: [{"x-id", "1"}, {"content-type", "text/plain"}],
                            retry: false
                          )
               end)

      [written] = read_pact(dir)["interactions"]
      assert written["request"]["query"] == %{"tag" => ["a", "b"]}
      assert written["request"]["headers"]["x-id"] == ["1"]
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

  describe "run/4 XML and form-urlencoded bodies" do
    # Each of these shapes made pact_ffi panic inside `with_body`, which aborts
    # the VM, until the description was validated before the native call.
    @xml_panic_shape %{"root" => %{"a" => "b"}}

    defp xml_interaction(request_opts, response_opts) do
      HTTP.interaction("xml body")
      |> HTTP.with_request(:post, "/xml", request_opts)
      |> HTTP.will_respond_with(200, response_opts)
    end

    test "a map that is not an XML description is rejected, by header or explicit type", %{
      pact: pact,
      tmp_dir: dir
    } do
      cases = [
        {"header", [headers: %{"Content-Type" => "application/xml"}]},
        {"lowercase header", [headers: %{"content-type" => "text/xml; charset=utf-8"}]},
        {"suffix header", [headers: %{"Content-Type" => "application/soap+xml"}]},
        {"matcher header",
         [headers: %{"Content-Type" => regex("application/xml", "application/.*")}]},
        {"list header", [headers: %{"Content-Type" => ["application/xml"]}]},
        {"explicit type", [content_type: "application/xml"]},
        {"explicit type wins over header",
         [content_type: "text/xml", headers: %{"Content-Type" => "application/json"}]}
      ]

      for {name, opts} <- cases, part <- [:request, :response] do
        i =
          case part do
            :request ->
              HTTP.interaction("bad #{name}")
              |> HTTP.with_request(:post, "/x", [body: @xml_panic_shape] ++ opts)

            :response ->
              HTTP.interaction("bad #{name}")
              |> HTTP.with_request(:get, "/x")
              |> HTTP.will_respond_with(200, [body: @xml_panic_shape] ++ opts)
          end

        assert {:error,
                %PactEx.Error{
                  code: -101,
                  function: "PactEx.Consumer.start_mock_server/3",
                  message: message
                }} = Consumer.start_mock_server(pact, [i])

        assert message =~ "#{part} body"
        assert message =~ ~s("bad #{name}")
        assert message =~ "$.root"
        assert message =~ "string"
      end

      refute File.exists?(pact_path(dir))
    end

    test "run/4 returns the error without calling the function", %{pact: pact} do
      i =
        xml_interaction([],
          headers: %{"Content-Type" => "application/xml"},
          body: @xml_panic_shape
        )

      parent = self()

      assert {:error, %PactEx.Error{code: -101}} =
               Consumer.run(pact, [i], fn _ -> send(parent, :called) end)

      refute_received :called
    end

    test "an invalid description in a later interaction stops everything before any server starts",
         %{pact: pact} do
      good = simple("good", "/good")

      bad =
        xml_interaction([],
          headers: %{"Content-Type" => "application/xml"},
          body: @xml_panic_shape
        )

      assert {:error, %PactEx.Error{code: -101}} = Consumer.start_mock_server(pact, [good, bad])
    end

    test "a list or a map without root is rejected as an XML body", %{pact: pact} do
      for body <- [[%{"root" => %{"name" => "a"}}], %{"name" => "a"}, %{}] do
        i = xml_interaction([], content_type: "application/xml", body: body)

        assert {:error, %PactEx.Error{code: -101, message: message}} =
                 Consumer.start_mock_server(pact, [i])

        assert message =~ "XML"
      end
    end

    test "each panic shape from pact_ffi is rejected, none aborts the VM", %{pact: pact} do
      shapes = [
        %{"root" => %{"pact:matcher:type" => "type"}},
        %{"root" => %{"pact:matcher:type" => "type", "value" => "x"}},
        %{"root" => %{"pact:matcher:type" => "type", "value" => %{"children" => []}}},
        %{"root" => %{"name" => "r", "children" => nil}},
        %{"root" => %{"name" => "r", "children" => "x"}},
        %{"root" => %{"name" => "r", "children" => ["x"]}},
        %{"root" => %{"name" => "r", "children" => [%{"name" => "c", "examples" => -1}]}},
        %{"root" => %{"name" => "r", "children" => [%{"content" => "t", "examples" => 1.5}]}},
        %{
          "root" => %{
            "name" => "r",
            "attributes" => %{"id" => %{"pact:matcher:type" => "type"}}
          }
        }
      ]

      for shape <- shapes do
        i = xml_interaction([], content_type: "application/xml", body: shape)

        assert {:error, %PactEx.Error{code: -101}} = Consumer.start_mock_server(pact, [i]),
               inspect(shape)
      end
    end

    test "a content type that is not XML leaves the map untouched, whatever the header says",
         %{pact: pact, tmp_dir: dir} do
      i =
        HTTP.interaction("json wins")
        |> HTTP.with_request(:get, "/j")
        |> HTTP.will_respond_with(200,
          headers: %{"Content-Type" => "application/xml"},
          content_type: "application/json",
          body: @xml_panic_shape
        )

      assert :ok =
               Consumer.run(pact, [i], fn m ->
                 resp = Req.get!(m.url <> "/j", decode_body: false, retry: false)
                 assert JSON.decode!(resp.body) == @xml_panic_shape
               end)

      assert body_of(dir, "response")["contentType"] == "application/json"
    end

    test "a valid XML description is served as XML and recorded as application/xml", %{
      pact: pact,
      tmp_dir: dir
    } do
      request_description = %{
        "root" => %{
          "name" => "note",
          "attributes" => %{
            "id" => %{"pact:matcher:type" => "regex", "value" => "a1", "regex" => "[a-z]\\d"}
          },
          "children" => [
            %{
              "name" => "to",
              "children" => [
                %{
                  "content" => "Ann",
                  "matcher" => %{"pact:matcher:type" => "regex", "regex" => "[A-Za-z]+"}
                }
              ]
            }
          ]
        }
      }

      response_description = %{
        "root" => %{
          "name" => "library",
          "attributes" => %{"version" => 2, "open" => true, "nothing" => nil},
          "children" => [
            %{"name" => "title", "children" => [%{"content" => "Elixir"}]},
            %{
              "pact:matcher:type" => "type",
              "value" => %{
                "name" => "book",
                "attributes" => %{"isbn" => "1"},
                "children" => [%{"name" => "price", "children" => [%{"content" => 10}]}]
              },
              "examples" => 2
            },
            %{"name" => "empty", "examples" => 0},
            %{"content" => "tail"}
          ]
        }
      }

      i =
        xml_interaction(
          [headers: %{"Content-Type" => "application/xml"}, body: request_description],
          headers: %{"Content-Type" => "application/xml"},
          body: response_description
        )

      assert :ok =
               Consumer.run(pact, [i], fn m ->
                 resp =
                   Req.post!(m.url <> "/xml",
                     body:
                       ~s(<?xml version="1.0" encoding="UTF-8"?><note id="z9"><to>Bo</to></note>),
                     headers: [{"content-type", "application/xml"}],
                     decode_body: false,
                     retry: false
                   )

                 assert resp.status == 200
                 assert served_content_type(resp) == ["application/xml"]
                 assert resp.body =~ "version='2'"
                 assert resp.body =~ "open='true'"
                 assert resp.body =~ "nothing=''"
                 assert resp.body =~ "<title>Elixir</title>"

                 assert resp.body =~
                          "<book isbn='1'><price>10</price></book><book isbn='1'><price>10</price></book>"

                 assert length(String.split(resp.body, "<book ")) == 3
                 refute resp.body =~ "<empty"
                 assert resp.body =~ "tail</library>"
               end)

      [written] = read_pact(dir)["interactions"]

      for part <- ["request", "response"] do
        assert written[part]["body"]["contentType"] == "application/xml"

        assert [{"Content-Type", ["application/xml"]}] =
                 content_type_entries(written[part]["headers"])
      end

      assert written["request"]["body"]["content"] =~ "<note"
      assert written["response"]["body"]["content"] =~ "<library"

      request_rules = written["request"]["matchingRules"]["body"]
      assert Enum.any?(Map.keys(request_rules), &(&1 =~ "#text"))
      assert Enum.any?(Map.keys(request_rules), &(&1 =~ "@id"))
      assert Enum.any?(Map.keys(written["response"]["matchingRules"]["body"]), &(&1 =~ "book"))
    end

    test "a request that breaks the described matcher is reported as a mismatch", %{pact: pact} do
      description = %{
        "root" => %{
          "name" => "note",
          "attributes" => %{
            "id" => %{"pact:matcher:type" => "regex", "value" => "a1", "regex" => "[a-z]\\d"}
          }
        }
      }

      i =
        xml_interaction([content_type: "application/xml", body: description], [])

      assert {:error, %PactEx.MismatchError{}} =
               Consumer.run(pact, [i], fn m ->
                 Req.post!(m.url <> "/xml",
                   body: ~s(<?xml version="1.0" encoding="UTF-8"?><note id="99"/>),
                   headers: [{"content-type", "application/xml"}],
                   retry: false
                 )
               end)
    end

    test "keys that collide once turned into strings are rejected, for every content type", %{
      pact: pact,
      tmp_dir: dir
    } do
      # JSON.encode! writes both keys. Elixir's decoder keeps the first and
      # serde_json (pact_ffi) the last, so the validator and pact_ffi would
      # read different bodies. With an XML type the second one aborted the VM.
      collide = %{:root => %{"name" => "ok"}, "root" => %{"a" => "b"}}

      cases = [
        {"xml header", [headers: %{"Content-Type" => "application/xml"}], collide, "$"},
        {"xml explicit", [content_type: "text/xml"], collide, "$"},
        {"json default", [], %{"a" => 1, :a => 2}, "$"},
        {"form", [content_type: "application/x-www-form-urlencoded"], %{"a" => 1, :a => 2}, "$"},
        {"nested in a list", [], %{"items" => [%{"ok" => 1}, %{:id => 1, "id" => 2}]},
         "$.items[1]"},
        {"integer key", [], %{1 => "a", "1" => "b"}, "$"}
      ]

      for {name, opts, body, path} <- cases, part <- [:request, :response] do
        i =
          case part do
            :request ->
              HTTP.interaction("collide #{name}")
              |> HTTP.with_request(:post, "/c", [body: body] ++ opts)

            :response ->
              HTTP.interaction("collide #{name}")
              |> HTTP.with_request(:get, "/c")
              |> HTTP.will_respond_with(200, [body: body] ++ opts)
          end

        assert {:error, %PactEx.Error{code: -101, message: message}} =
                 Consumer.start_mock_server(pact, [i])

        assert message =~ "#{part} body"
        assert message =~ ~s("collide #{name}")
        assert message =~ "#{path}: the key"
      end

      refute File.exists?(pact_path(dir))
    end

    test "keys that differ in type but not in value are fine when they do not collide", %{
      pact: pact
    } do
      i =
        HTTP.interaction("atoms")
        |> HTTP.with_request(:get, "/atoms")
        |> HTTP.will_respond_with(200, body: %{ok: true, other: %{"nested" => [%{a: 1}]}})

      assert :ok =
               Consumer.run(pact, [i], fn m ->
                 resp = Req.get!(m.url <> "/atoms", retry: false)
                 assert resp.body == %{"ok" => true, "other" => %{"nested" => [%{"a" => 1}]}}
               end)
    end

    test "a content type pact_ffi cannot parse falls back to the XML header, so the map is checked",
         %{pact: pact} do
      for ct <- ["application/json; charset", "application/json,", "application/xml "] do
        i =
          xml_interaction([],
            headers: %{"Content-Type" => "application/xml"},
            content_type: ct,
            body: @xml_panic_shape
          )

        assert {:error, %PactEx.Error{code: -101, message: message}} =
                 Consumer.start_mock_server(pact, [i]),
               ct

        assert message =~ "$.root"
      end
    end

    test "a valid description with an unparseable explicit type is served as XML by the header",
         %{pact: pact, tmp_dir: dir} do
      i =
        xml_interaction([],
          headers: %{"Content-Type" => "application/xml"},
          content_type: "application/json; charset",
          body: xml_description("a", "b")
        )

      assert :ok =
               Consumer.run(pact, [i], fn m ->
                 resp = Req.post!(m.url <> "/xml", decode_body: false, retry: false)
                 assert resp.body =~ "<root><a>b</a></root>"
               end)

      assert body_of(dir, "response")["contentType"] == "application/xml"
    end

    test "a malformed XML header that pact_ffi ignores does not make the map an XML description",
         %{pact: pact} do
      for header <- ["application/xml; charset", "application/xml,"] do
        i =
          HTTP.interaction("malformed #{header}")
          |> HTTP.with_request(:get, "/mal")
          |> HTTP.will_respond_with(200,
            headers: %{"Content-Type" => header},
            body: @xml_panic_shape
          )

        assert :ok =
                 Consumer.run(pact, [i], fn m ->
                   resp = Req.get!(m.url <> "/mal", decode_body: false, retry: false)
                   assert JSON.decode!(resp.body) == @xml_panic_shape
                 end),
               header
      end
    end

    test "a type that is both JSON and XML is JSON, as in pact_ffi", %{pact: pact} do
      i =
        HTTP.interaction("json and xml")
        |> HTTP.with_request(:get, "/jx")
        |> HTTP.will_respond_with(200,
          headers: %{"Content-Type" => "application/xml+json"},
          body: @xml_panic_shape
        )

      assert :ok =
               Consumer.run(pact, [i], fn m ->
                 resp = Req.get!(m.url <> "/jx", decode_body: false, retry: false)
                 assert JSON.decode!(resp.body) == @xml_panic_shape
               end)
    end

    test "an arrayContains matcher in a form body is served from its variants", %{pact: pact} do
      i =
        HTTP.interaction("form array contains")
        |> HTTP.with_request(:get, "/fa")
        |> HTTP.will_respond_with(200,
          content_type: "application/x-www-form-urlencoded",
          body: %{"tag" => %{"pact:matcher:type" => "arrayContains", "variants" => ["a", "b"]}}
        )

      assert :ok =
               Consumer.run(pact, [i], fn m ->
                 resp = Req.get!(m.url <> "/fa", decode_body: false, retry: false)
                 assert resp.body == "tag=a&tag=b"
               end)
    end

    test "a form key that starts with pact: is rejected", %{pact: pact} do
      i =
        HTTP.interaction("form pact key")
        |> HTTP.with_request(:get, "/fp")
        |> HTTP.will_respond_with(200,
          content_type: "application/x-www-form-urlencoded",
          body: %{"pact:x" => "1", "a" => "b"}
        )

      assert {:error, %PactEx.Error{code: -101, message: message}} =
               Consumer.start_mock_server(pact, [i])

      assert message =~ "$.pact:x"
    end

    test "a struct whose encoder repeats a key is rejected", %{pact: pact} do
      body = struct(CollidingRoot, root: %{"name" => "ok", :children => [], "children" => []})

      i =
        xml_interaction([], headers: %{"Content-Type" => "application/xml"}, body: body)

      assert {:error, %PactEx.Error{code: -101, message: message}} =
               Consumer.start_mock_server(pact, [i])

      assert message =~ "$.root"
      assert message =~ ~s(the key "children")
    end

    test "an improper list in a body is a PactEx.Error, not a crash", %{pact: pact} do
      i = xml_interaction([], body: %{"a" => bad_improper()})

      assert {:error, %PactEx.Error{code: -101, message: message}} =
               Consumer.start_mock_server(pact, [i])

      assert message =~ "JSON"
    end

    test "keys that collide in a matcher header or provider state params are rejected", %{
      pact: pact
    } do
      header =
        HTTP.interaction("header collide")
        |> HTTP.with_request(:get, "/x", headers: %{"x-a" => %{:value => "a", "value" => "b"}})

      state =
        HTTP.interaction("state collide")
        |> HTTP.given("s", %{:a => 1, "a" => 2})
        |> HTTP.with_request(:get, "/x")

      path =
        HTTP.interaction("path collide")
        |> HTTP.with_request(:get, %{:value => "a", "value" => "b"})

      for i <- [header, state, path] do
        assert {:error, %PactEx.Error{code: -101, message: message}} =
                 Consumer.start_mock_server(pact, [i])

        assert message =~ "more than once"
      end
    end

    test "a padded Content-Type is trimmed, and the header is written trimmed", %{
      pact: pact,
      tmp_dir: dir
    } do
      for padded <- [" application/xml", "application/xml ", "application/xml\t"] do
        bad =
          xml_interaction([], headers: %{"Content-Type" => padded}, body: @xml_panic_shape)

        assert {:error, %PactEx.Error{code: -101}} = Consumer.start_mock_server(pact, [bad]),
               inspect(padded)
      end

      i =
        xml_interaction([],
          headers: %{"content-type" => " application/xml "},
          body: xml_description("a", "b")
        )

      assert :ok =
               Consumer.run(pact, [i], fn m ->
                 resp = Req.post!(m.url <> "/xml", decode_body: false, retry: false)
                 assert resp.body =~ "<root><a>b</a></root>"
                 assert served_content_type(resp) == ["application/xml"]
               end)

      [written] = read_pact(dir)["interactions"]

      assert [{"Content-Type", ["application/xml"]}] =
               content_type_entries(written["response"]["headers"])
    end

    test "a header the user wrote as JSON text or a matcher cannot steer pact_ffi", %{pact: pact} do
      headers = [
        ~s({"value":"application/xml"}),
        %{value: "application/xml"},
        %{"pact:matcher:type" => "type", "value" => [%{"value" => "application/xml"}]},
        %{"pact:matcher:type" => "regex", "regex" => ".*", "value" => "application/xml "}
      ]

      for header <- headers, extra <- [[], [content_type: "application/json; charset"]] do
        i =
          xml_interaction([],
            headers: %{"Content-Type" => header},
            body: @xml_panic_shape
          )

        i = %{i | response: struct(i.response, extra)}

        # Rejected when the type resolves to XML, served as JSON when it does not.
        case Consumer.start_mock_server(pact, [i]) do
          {:error, %PactEx.Error{code: -101}} -> :ok
          {:ok, mock} -> PactEx.MockServer.stop(mock)
        end
      end
    end

    test "a string body that is JSON text is checked as a description under an XML type", %{
      pact: pact
    } do
      i =
        xml_interaction([], content_type: "application/xml", body: ~s({"root":{"a":"b"}}))

      assert {:error, %PactEx.Error{code: -101, message: message}} =
               Consumer.start_mock_server(pact, [i])

      assert message =~ "$.root"
    end

    test "a string body that is a valid JSON description is turned into XML", %{pact: pact} do
      i =
        xml_interaction([],
          content_type: "application/xml",
          body: JSON.encode!(xml_description("a", "b"))
        )

      assert :ok =
               Consumer.run(pact, [i], fn m ->
                 resp = Req.post!(m.url <> "/xml", decode_body: false, retry: false)
                 assert resp.body =~ "<root><a>b</a></root>"
               end)
    end

    test "a string body under a form type that pact_ffi sniffs as JSON but cannot parse is rejected",
         %{pact: pact} do
      # pact_ffi unwraps the parse of such a text and panics.
      for text <- ["1=a&2=b", "null_flag=1", "true=1", "123 items"] do
        i =
          HTTP.interaction("sniffed form")
          |> HTTP.with_request(:get, "/f")
          |> HTTP.will_respond_with(200,
            headers: %{"Content-Type" => "application/x-www-form-urlencoded"},
            body: text
          )

        assert {:error, %PactEx.Error{code: -101, message: message}} =
                 Consumer.start_mock_server(pact, [i]),
               text

        assert message =~ "not valid JSON"
      end
    end

    test "a string body nested 128 levels or more names serde_json's limit", %{pact: pact} do
      deep = String.duplicate("[", 200) <> String.duplicate("]", 200)

      i =
        HTTP.interaction("too deep")
        |> HTTP.with_request(:get, "/f")
        |> HTTP.will_respond_with(200,
          headers: %{"Content-Type" => "application/x-www-form-urlencoded"},
          body: ~s({"a":#{deep}})
        )

      assert {:error, %PactEx.Error{code: -101, message: message}} =
               Consumer.start_mock_server(pact, [i])

      assert message =~ "nested 128 levels or more (serde_json's limit)"
      refute message =~ "not valid JSON"
    end

    test "a map body nested 128 levels deep names serde_json's limit", %{pact: pact} do
      body = Enum.reduce(1..128, "x", fn _, acc -> %{"k" => acc} end)

      i =
        HTTP.interaction("too deep map")
        |> HTTP.with_request(:get, "/f")
        |> HTTP.will_respond_with(200,
          headers: %{"Content-Type" => "application/x-www-form-urlencoded"},
          body: body
        )

      assert {:error, %PactEx.Error{code: -101, message: message}} =
               Consumer.start_mock_server(pact, [i])

      assert message =~ "nested 128 levels or more (serde_json's limit)"
    end

    test "a string body under a form type that is not sniffed as JSON stays byte for byte", %{
      pact: pact
    } do
      i =
        HTTP.interaction("plain form")
        |> HTTP.with_request(:get, "/f")
        |> HTTP.will_respond_with(200,
          headers: %{"Content-Type" => "application/x-www-form-urlencoded"},
          body: "a=1&b=2"
        )

      assert :ok =
               Consumer.run(pact, [i], fn m ->
                 resp = Req.get!(m.url <> "/f", decode_body: false, retry: false)
                 assert resp.body == "a=1&b=2"
               end)
    end

    test "form-type equivalents of the header cases: padded and unparseable types", %{pact: pact} do
      for {name, opts} <- [
            {"padded header",
             [headers: %{"Content-Type" => " application/x-www-form-urlencoded"}]},
            {"padded explicit", [content_type: "application/x-www-form-urlencoded "]},
            {"invalid explicit, form header",
             [
               headers: %{"Content-Type" => "application/x-www-form-urlencoded"},
               content_type: "application/json; charset"
             ]}
          ] do
        i =
          HTTP.interaction("form #{name}")
          |> HTTP.with_request(:get, "/f")
          |> HTTP.will_respond_with(200, [body: %{"user" => %{"name" => "Ann"}}] ++ opts)

        assert {:error, %PactEx.Error{code: -101, message: message}} =
                 Consumer.start_mock_server(pact, [i]),
               name

        assert message =~ "$.user"
      end
    end

    test "a raw XML string is still sent byte for byte",
         %{pact: pact, tmp_dir: dir} do
      xml = ~s(<root><a>b</a></root>)

      i = xml_interaction([], content_type: "application/xml", body: xml)

      assert :ok =
               Consumer.run(pact, [i], fn m ->
                 resp = Req.post!(m.url <> "/xml", decode_body: false, retry: false)
                 assert resp.body == xml
               end)

      assert %{"content" => ^xml, "contentType" => "application/xml"} = body_of(dir, "response")
    end

    test "a form-urlencoded map is served as a form body and recorded", %{
      pact: pact,
      tmp_dir: dir
    } do
      description = %{
        "name" => "Ann Lee",
        "age" => 30,
        "tag" => ["p", "q"],
        "code" => regex("a1", "[a-z]\\d")
      }

      i =
        HTTP.interaction("form body")
        |> HTTP.with_request(:post, "/form",
          headers: %{"content-type" => "application/x-www-form-urlencoded"},
          body: description
        )
        |> HTTP.will_respond_with(200,
          content_type: "application/x-www-form-urlencoded",
          body: %{"ok" => "yes", "n" => [1, 2]}
        )

      assert :ok =
               Consumer.run(pact, [i], fn m ->
                 resp =
                   Req.post!(m.url <> "/form",
                     body: "age=30&code=a1&name=Ann+Lee&tag=p&tag=q",
                     headers: [{"content-type", "application/x-www-form-urlencoded"}],
                     decode_body: false,
                     retry: false
                   )

                 assert resp.status == 200
                 assert resp.body == "n=1&n=2&ok=yes"
                 assert served_content_type(resp) == ["application/x-www-form-urlencoded"]
               end)

      [written] = read_pact(dir)["interactions"]

      assert %{"contentType" => "application/x-www-form-urlencoded", "content" => request_body} =
               written["request"]["body"]

      assert request_body =~ "name=Ann+Lee"
      assert request_body =~ "tag=p&tag=q"
      assert get_in(written, ["request", "matchingRules", "body", "$.code"])
    end

    test "form-urlencoded values that pact_ffi would drop are rejected", %{pact: pact} do
      cases = [
        {%{"user" => %{"name" => "Ann"}}, "$.user"},
        {%{"flag" => true}, "$.flag"},
        {%{"nothing" => nil}, "$.nothing"},
        {%{"l" => ["a", %{"k" => "v"}]}, "$.l[1]"},
        {[%{"a" => "b"}], "not an object"}
      ]

      for {body, fragment} <- cases, part <- [:request, :response] do
        i =
          case part do
            :request ->
              HTTP.interaction("bad form")
              |> HTTP.with_request(:post, "/f",
                content_type: "application/x-www-form-urlencoded",
                body: body
              )

            :response ->
              HTTP.interaction("bad form")
              |> HTTP.with_request(:get, "/f")
              |> HTTP.will_respond_with(200,
                headers: %{"Content-Type" => "application/x-www-form-urlencoded"},
                body: body
              )
          end

        assert {:error, %PactEx.Error{code: -101, message: message}} =
                 Consumer.start_mock_server(pact, [i])

        assert message =~ "#{part} body"
        assert message =~ ~s("bad form")
        assert message =~ fragment
      end
    end

    test "a raw form string is sent byte for byte", %{pact: pact} do
      i =
        HTTP.interaction("raw form")
        |> HTTP.with_request(:get, "/rf")
        |> HTTP.will_respond_with(200,
          content_type: "application/x-www-form-urlencoded",
          body: "a=1&b=%7B%7D"
        )

      assert :ok =
               Consumer.run(pact, [i], fn m ->
                 resp = Req.get!(m.url <> "/rf", decode_body: false, retry: false)
                 assert resp.body == "a=1&b=%7B%7D"
               end)
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
      assert_stopped(port)
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
