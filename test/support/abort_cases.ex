defmodule PactEx.AbortCases do
  @moduledoc """
  Test support for the abort matrix (`test/abort_matrix_test.exs`).

  A body that pact_ffi cannot handle panics, and the panic aborts the whole
  OS process. So each case runs in its own `mix run` process through
  `test/support/abort_cases/run.exs`, and a case that aborts fails one test
  instead of killing the suite.

  `all/0` is the list of cases. Each has a `name`, the `expect`ed outcome
  (`:ok` when the server starts and answers, `:invalid` when `PactEx` returns a
  `-101` error) and a `build` function that makes
  the interaction. `run/1` runs one case in the current process and prints
  the outcome on a line that starts with `ABORT_CASE_RESULT`.
  """

  alias PactEx.HTTP

  @xml "application/xml"
  @form "application/x-www-form-urlencoded"
  @bad_description %{"root" => %{"a" => "b"}}
  @good_description %{
    "root" => %{
      "name" => "root",
      "children" => [%{"name" => "a", "children" => [%{"content" => "b"}]}]
    }
  }

  # -- Cases ---------------------------------------------------------------

  @doc "Every case: fixed reviewer probes first, then the generated matrices."
  def all,
    do: fixed() ++ type_matrix() ++ body_matrix() ++ form_matrix() ++ empty_content_type()

  @doc "The groups the test runs, as `{group, cases}`."
  def groups do
    [
      {"fixed", fixed()},
      {"explicit type x header", type_matrix()},
      {"body x type", body_matrix()},
      {"form", form_matrix()},
      {"empty Content-Type", empty_content_type()}
    ]
  end

  # Scenarios found by the reviews, each of which aborted the VM once.
  defp fixed do
    bad = "application/json; charset"
    hdr = fn value -> %{"Content-Type" => value} end

    matcher = fn value ->
      %{"pact:matcher:type" => "regex", "regex" => ".*", "value" => value}
    end

    response = fn name, expect, opts, body ->
      case_response(name, expect, opts, body)
    end

    [
      response.(
        "dup.exs: map with an XML header",
        :invalid,
        [headers: hdr.(@xml)],
        @bad_description
      ),
      response.("dupkey.exs: atom and string keys", :invalid, [headers: hdr.(@xml)], colliding()),
      response.(
        "ctparam.exs: explicit 'application/json; charset'",
        :invalid,
        [headers: hdr.(@xml), content_type: bad],
        @bad_description
      ),
      response.(
        "ctparam.exs: explicit 'application/json,'",
        :invalid,
        [headers: hdr.(@xml), content_type: "application/json,"],
        @bad_description
      ),
      response.(
        "probe ws_trail",
        :invalid,
        [headers: hdr.("application/xml ")],
        @bad_description
      ),
      response.("probe ws_lead", :invalid, [headers: hdr.(" application/xml")], @bad_description),
      response.("probe ws_tab", :invalid, [headers: hdr.("application/xml\t")], @bad_description),
      response.(
        "probe ws_matcher",
        :invalid,
        [headers: hdr.(matcher.("application/xml "))],
        @bad_description
      ),
      response.(
        "probe json_obj_string",
        :ok,
        [headers: hdr.(~s({"value":"application/xml"}))],
        @bad_description
      ),
      response.(
        "probe atom_map_explicit",
        :ok,
        [headers: hdr.(%{value: @xml}), content_type: bad],
        @bad_description
      ),
      response.(
        "probe nested_matcher_explicit",
        :ok,
        [
          headers:
            hdr.(%{
              "pact:matcher:type" => "type",
              "value" => [%{"pact:matcher:type" => "type", "value" => @xml}]
            }),
          content_type: bad
        ],
        @bad_description
      ),
      response.(
        "probe ws_explicit",
        :invalid,
        [headers: hdr.("application/xml "), content_type: bad],
        @bad_description
      ),
      response.(
        "struct.exs: struct deriving JSON.Encoder with colliding keys",
        :invalid,
        [headers: hdr.(@xml)],
        struct(CollidingRoot,
          root: %{"name" => "ok", :children => [], "children" => [%{"a" => "b"}]}
        )
      ),
      response.(
        "strjson.exs: JSON text under an XML type",
        :invalid,
        [content_type: @xml],
        ~s({"root":{"a":"b"}})
      ),
      response.("improper list in a body", :invalid, [], %{"a" => improper()}),
      %{
        name: "hdrcollide.exs: colliding keys in a header matcher",
        expect: :invalid,
        build: fn ->
          HTTP.interaction("hdr collide")
          |> HTTP.with_request(:get, "/x")
          |> HTTP.will_respond_with(200,
            headers: %{
              "Content-Type" => %{
                "pact:matcher:type" => "type",
                :value => @xml,
                "value" => "text/plain"
              }
            },
            content_type: bad,
            body: @bad_description
          )
        end
      },
      %{
        name: "hdrcollide.exs: colliding keys in provider state params",
        expect: :invalid,
        build: fn ->
          HTTP.interaction("state collide")
          |> HTTP.given("s", %{:a => 1, "a" => 2})
          |> HTTP.with_request(:get, "/x")
        end
      },
      %{
        name: "request body with an XML header",
        expect: :invalid,
        build: fn ->
          HTTP.interaction("request body")
          |> HTTP.with_request(:post, "/x", headers: hdr.(@xml), body: @bad_description)
        end
      }
    ]
  end

  # explicit content type x Content-Type header, with a body that is invalid
  # as an XML description. Each cell is pinned to the outcome that follows from
  # `PactEx.Consumer.Apply.choose_type/3`: the first of the explicit type, the
  # Content-Type header and the default `application/json` that is trimmed and
  # parsed by pact_models wins. The body is rejected (:invalid) only when that
  # type is XML. Under any other type it is JSON and the server starts (:ok).
  #
  # What each header column contributes as a candidate:
  #
  #   * absent: none, so the default (JSON) applies;
  #   * plain xml, padded xml, matcher padded: the string, trimmed, is
  #     `application/xml`, so XML wins unless an explicit type parses first;
  #   * json text: the string `{"value":"application/xml"}` is not a content
  #     type pact_models parses as XML, so it adds nothing;
  #   * atom map, nested list matcher: `header_value/1` only reads a string
  #     under the "value" key, and these have an atom key or a list value, so
  #     they add no candidate.
  #
  # And each explicit row:
  #
  #   * none: the header decides, as above;
  #   * json: parses and is not XML, so it wins over every header;
  #   * padded xml, xml, +xml: parse (after the trim) as XML, and win;
  #   * mime-invalid param, mime-invalid comma: pact_models cannot parse them,
  #     so they are skipped and the header decides, as for "none".
  defp type_matrix do
    headers = [
      {"absent", []},
      {"plain xml", [headers: %{"Content-Type" => @xml}]},
      {"padded xml", [headers: %{"Content-Type" => " application/xml"}]},
      {"matcher padded",
       [
         headers: %{
           "Content-Type" => %{"pact:matcher:type" => "type", "value" => "application/xml "}
         }
       ]},
      {"json text", [headers: %{"Content-Type" => ~s({"value":"application/xml"})}]},
      {"atom map", [headers: %{"Content-Type" => %{value: @xml}}]},
      {"nested list matcher",
       [
         headers: %{
           "Content-Type" => %{
             "pact:matcher:type" => "type",
             "value" => [%{"pact:matcher:type" => "type", "value" => @xml}]
           }
         }
       ]}
    ]

    # The outcome of each header column, in the order of `headers`.
    header_decides = [:ok, :invalid, :invalid, :invalid, :ok, :ok, :ok]

    explicit = [
      {"none", [], header_decides},
      {"json", [content_type: "application/json"], List.duplicate(:ok, 7)},
      {"padded xml", [content_type: " application/xml "], List.duplicate(:invalid, 7)},
      {"mime-invalid param", [content_type: "application/json; charset"], header_decides},
      {"mime-invalid comma", [content_type: "application/json,"], header_decides},
      {"xml", [content_type: @xml], List.duplicate(:invalid, 7)},
      {"+xml", [content_type: "text/foo+xml"], List.duplicate(:invalid, 7)}
    ]

    for {en, eopts, expected} <- explicit,
        {{hn, hopts}, expect} <- Enum.zip(headers, expected) do
      case_response(
        "types: explicit #{en}, header #{hn}",
        expect,
        eopts ++ hopts,
        @bad_description
      )
    end
  end

  # Each kind of body under XML types.
  defp body_matrix do
    bodies = [
      {"valid description", @good_description, :ok},
      {"invalid description", @bad_description, :invalid},
      {"struct with colliding keys",
       struct(CollidingRoot, root: %{"name" => "ok", :children => [], "children" => []}),
       :invalid},
      {"atom and string keys", colliding(), :invalid},
      {"JSON text, invalid description", ~s({"root":{"a":"b"}}), :invalid},
      {"JSON text, valid description", JSON.encode!(@good_description), :ok},
      {"raw XML string", "<root><a>b</a></root>", :ok}
    ]

    types = [
      {"plain xml header", [headers: %{"Content-Type" => @xml}]},
      {"explicit xml", [content_type: @xml]},
      {"padded explicit xml, invalid header",
       [content_type: " application/xml ", headers: %{"Content-Type" => "nonsense"}]}
    ]

    for {bn, body, expect} <- bodies, {tn, topts} <- types do
      case_response("bodies: #{bn}, #{tn}", expect, topts, body)
    end
  end

  defp form_matrix do
    bodies = [
      {"valid map", %{"a" => "1", "b" => [1, 2]}, :ok},
      {"nested map", %{"u" => %{"n" => "x"}}, :invalid},
      {"boolean", %{"f" => true}, :invalid},
      {"text sniffed as JSON", "1=a&2=b", :invalid},
      {"text starting with null", "null_flag=1", :invalid},
      {"raw form", "a=1&b=2", :ok},
      {"colliding keys", %{:a => 1, "a" => 2}, :invalid}
    ]

    types = [
      {"plain header", [headers: %{"Content-Type" => @form}]},
      {"explicit", [content_type: @form]},
      {"padded header", [headers: %{"Content-Type" => " " <> @form}]},
      {"invalid explicit, form header",
       [content_type: "application/json; charset", headers: %{"Content-Type" => @form}]}
    ]

    for {bn, body, expect} <- bodies, {tn, topts} <- types do
      case_response("form: #{bn}, #{tn}", expect, topts, body)
    end
  end

  # A Content-Type header that pact_ffi stores as an empty list makes
  # `pactffi_with_body` panic (pact_models indexes `v[0]`). All of these are
  # rejected, with or without a body. A list with an empty element at any
  # position is rejected too: pact_ffi records `["", "text/plain"]`, which no
  # client can match. So are an empty or whitespace-only string and a `[]` header
  # value, which the mock server could never match either. Anything that keeps
  # a non-blank value everywhere is served.
  defp empty_content_type do
    empty = %{"value" => []}
    matcher = %{"pact:matcher:type" => "type", "value" => []}
    regex = %{"pact:matcher:type" => "regex", "regex" => ".*", "value" => []}
    ct_header = fn name -> %{"Content-Type" => name} end
    map_body = %{"a" => 1}

    rejected_headers = [
      {"value", ct_header.(empty)},
      {"matcher", ct_header.(matcher)},
      {"regex matcher", ct_header.(regex)},
      {"atom keys", ct_header.(%{value: []})},
      {"atom key matcher", ct_header.(%{:"pact:matcher:type" => "type", :value => []})},
      {"json text", ct_header.(~s({"value":[]}))},
      {"json text, spaced", ct_header.(~s(  {"value" :  [ ] }\n))},
      {"json text, matcher", ct_header.(~s({"pact:matcher:type":"type","value":[]}))},
      {"json text, repeated key", ct_header.(~s({"value":"a","value":[]}))},
      {"list of one", ct_header.([empty])},
      {"list, last element", ct_header.(["text/plain", empty])},
      {"list, empty twice", ct_header.([empty, empty])},
      {"list, after a non-empty value", ct_header.([%{"value" => ["a"]}, empty])},
      {"list, empty first element, then a value", ct_header.([empty, "text/plain"])},
      {"list, empty matcher first, then an array",
       ct_header.([matcher, %{"value" => ["a/b", "c/d"]}])},
      {"list, empty in the middle", ct_header.(["text/csv", empty, "text/plain"])},
      {"list, empty first, then empty twice", ct_header.([empty, empty, "text/plain"])},
      {"list of json texts", ct_header.([~s({"value":[]})])},
      {"lowercase name", %{"content-type" => empty}},
      {"atom name", %{"Content-Type": empty}},
      {"lowercase atom name", %{"content-type": empty}},
      {"empty string", ct_header.("")},
      {"blank string", ct_header.("  ")},
      {"whole header is an empty list", ct_header.([])},
      {"list, empty string first", ct_header.(["", "text/plain"])},
      {"list, empty string last", ct_header.(["text/plain", ""])},
      {"list, blank string in the middle", ct_header.(["a/b", " ", "text/plain"])},
      {"matcher with an empty string", ct_header.(%{"value" => ""})},
      {"matcher with a blank string",
       ct_header.(%{"pact:matcher:type" => "type", "value" => " "})},
      {"array with an empty string", ct_header.(%{"value" => ["a/b", ""]})},
      {"json text, blank string", ct_header.(~s({"value":"  "}))},
      {"lowercase name, empty string", %{"content-type" => ""}}
    ]

    # {name, body, options}
    all_bodies = [
      {"map body", map_body, []},
      {"list body", [map_body], []},
      {"string body", "hello", []},
      {"empty string body", "", []},
      {"explicit json type and map body", map_body, [content_type: "application/json"]},
      {"explicit text type and string body", "x", [content_type: "text/plain"]},
      {"binary body", <<255, 0, 1>>, []},
      {"no body", nil, []}
    ]

    some_bodies =
      Enum.filter(all_bodies, &(elem(&1, 0) in ["map body", "string body", "no body"]))

    core = ["value", "matcher", "json text", "empty string", "blank string"]

    rejected =
      for {hn, headers} <- rejected_headers,
          {bn, body, bopts} <- if(hn in core, do: all_bodies, else: some_bodies) do
        case_response(
          "empty Content-Type: #{hn}, #{bn}",
          :invalid,
          [headers: headers] ++ bopts,
          body
        )
      end

    request_bodies = [
      {"map body", map_body, []},
      {"string body", "hello", []},
      {"empty string body", "", []},
      {"no body", nil, []},
      {"explicit json type and map body", map_body, [content_type: "application/json"]},
      {"explicit text type and string body", "hello", [content_type: "text/plain"]},
      {"explicit text type and empty string body", "", [content_type: "text/plain"]}
    ]

    request =
      for {hn, headers} <- [
            {"value", ct_header.(empty)},
            {"list, empty first", ct_header.([empty, "text/plain"])},
            {"empty string", ct_header.("")},
            {"list, empty string first", ct_header.(["", "text/plain"])}
          ],
          {bn, body, bopts} <- request_bodies do
        %{
          name: "empty Content-Type: request side, #{hn}, #{bn}",
          expect: :invalid,
          build: fn ->
            HTTP.interaction("abort case")
            |> HTTP.with_request(:post, "/x", [headers: headers, body: body] ++ bopts)
          end
        }
      end

    accepted_headers = [
      {"non-empty array value", ct_header.(%{"value" => ["application/json"]})},
      {"matcher with a string value",
       ct_header.(%{"pact:matcher:type" => "type", "value" => "text/plain"})},
      {"matcher with a non-empty array",
       ct_header.(%{"pact:matcher:type" => "type", "value" => ["a/b"]})},
      {"array of an empty array", ct_header.(%{"value" => [[]]})},
      {"null value", ct_header.(%{"value" => nil})},
      {"matcher without a value", ct_header.(%{"pact:matcher:type" => "type"})},
      {"object without a value", ct_header.(%{"other" => []})},
      {"json text, non-empty", ct_header.(~s({"value":["application/json"]}))},
      {"json text, not an object", ct_header.("[]")},
      {"list of strings", ct_header.(["application/json", "extra"])},
      {"another header with an empty array", %{"X-Other" => empty}}
    ]

    accepted =
      for {hn, headers} <- accepted_headers,
          {bn, body, bopts} <- Enum.filter(all_bodies, &(elem(&1, 0) in ["map body", "no body"])) do
        case_response(
          "empty Content-Type: accepted #{hn}, #{bn}",
          :ok,
          [headers: headers] ++ bopts,
          body
        )
      end

    rejected ++ request ++ accepted
  end

  defp case_response(name, expect, opts, body) do
    %{
      name: name,
      expect: expect,
      build: fn ->
        HTTP.interaction("abort case")
        |> HTTP.with_request(:get, "/x")
        |> HTTP.will_respond_with(200, [body: body] ++ opts)
      end
    }
  end

  defp colliding, do: %{:root => %{"name" => "ok"}, "root" => %{"a" => "b"}}
  defp improper, do: Function.identity([1 | 2])

  # -- Running one case in this process ----------------------------------------

  @doc """
  Runs the case called `name` and prints its outcome:

    * `:ok` - the mock server started and answered a request;
    * `{:error, code}` - `PactEx` returned a `PactEx.Error` with that code.
  """
  def run(name) do
    {:ok, _} = Application.ensure_all_started(:req)
    kase = Enum.find(all(), &(&1.name == name)) || raise "no abort case named #{inspect(name)}"
    pact = PactEx.new("abort-consumer", "abort-provider", pact_dir: System.tmp_dir!())

    outcome =
      case PactEx.Consumer.start_mock_server(pact, [kase.build.()]) do
        {:ok, mock} ->
          try do
            _ = Req.request(mock.url <> "/x", decode_body: false, retry: false)
            :ok
          after
            PactEx.MockServer.stop(mock)
          end

        {:error, %PactEx.Error{code: code}} ->
          {:error, code}
      end

    IO.puts("ABORT_CASE_RESULT " <> inspect(outcome))
  end
end
