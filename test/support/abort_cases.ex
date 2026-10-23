defmodule PactEx.AbortCases do
  @moduledoc """
  Test support for the abort matrix (`test/abort_matrix_test.exs`).

  A body that pact_ffi cannot handle panics, and the panic aborts the whole
  OS process. So each case runs in its own `mix run` process through
  `test/support/abort_cases/run.exs`, and a case that aborts fails one test
  instead of killing the suite.

  `all/0` is the list of cases. Each has a `name`, the `expect`ed outcome
  (`:ok` when the server starts and answers, `:invalid` when `PactEx` returns a
  `-101` error, `:any` when either is fine) and a `build` function that makes
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
  def all, do: fixed() ++ type_matrix() ++ body_matrix() ++ form_matrix()

  @doc "The groups the test runs, as `{group, cases}`."
  def groups do
    [
      {"fixed", fixed()},
      {"explicit type x header", type_matrix()},
      {"body x type", body_matrix()},
      {"form", form_matrix()}
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
  # as an XML description. Either the type resolves to XML and the body is
  # rejected, or it does not and the body is JSON.
  defp type_matrix do
    explicit = [
      {"none", []},
      {"json", [content_type: "application/json"]},
      {"padded xml", [content_type: " application/xml "]},
      {"mime-invalid param", [content_type: "application/json; charset"]},
      {"mime-invalid comma", [content_type: "application/json,"]},
      {"xml", [content_type: @xml]},
      {"+xml", [content_type: "text/foo+xml"]}
    ]

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

    for {en, eopts} <- explicit, {hn, hopts} <- headers do
      case_response("types: explicit #{en}, header #{hn}", :any, eopts ++ hopts, @bad_description)
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
