defmodule PactEx.Acceptance.MatchersEndToEndTest do
  # Every matcher in PactEx.Matchers against a real mock server. Request-side
  # cases let the client send a value that differs from the example, so the
  # mock server enforces the rule. Response-side cases check the example
  # comes back and that the pact records the rule.
  use ExUnit.Case, async: true

  import PactEx.Matchers
  alias PactEx.{Consumer, HTTP, MismatchError}

  @moduletag :tmp_dir

  @iso "yyyy-MM-dd'T'HH:mm:ssXXX"

  # {name, matcher, client value that differs from the example, expected rule}
  @request_cases [
    {"like/1", like("Ann"), "Bob", [%{"match" => "type"}]},
    {"each_like/2 with min", each_like("x", min: 2), ["a", "b", "c"],
     [%{"match" => "type", "min" => 2}]},
    {"regex/2", regex("abc-123", "^abc-\\d+$"), "abc-999",
     [%{"match" => "regex", "regex" => "^abc-\\d+$"}]},
    {"each_key/2", each_key(%{"k1" => 1}, "^k\\d$"), %{"k9" => 2}, :each_key},
    {"integer/1", integer(1), 42, [%{"match" => "integer"}]},
    {"decimal/1", decimal(1.5), 9.75, [%{"match" => "decimal"}]},
    {"boolean/1", boolean(true), false, [%{"match" => "boolean"}]},
    {"datetime/2", datetime("2026-10-22T10:00:00+00:00", @iso), "2025-01-02T03:04:05+01:00",
     [%{"match" => "datetime", "format" => @iso}]},
    {"include/1", include("ell"), "say hello there", [%{"match" => "include", "value" => "ell"}]}
  ]

  @response_cases [
    {"like/1", like("Ann"), "Ann", "type"},
    {"each_like/2 with min", each_like("x", min: 2), ["x", "x"], "type"},
    {"regex/2", regex("abc-123", "^abc-\\d+$"), "abc-123", "regex"},
    {"each_key/2", each_key(%{"k1" => 1}, "^k\\d$"), %{"k1" => 1}, "eachKey"},
    {"integer/1", integer(1), 1, "integer"},
    {"decimal/1", decimal(1.5), 1.5, "decimal"},
    {"boolean/1", boolean(true), true, "boolean"},
    {"datetime/2", datetime("2026-10-22T10:00:00+00:00", @iso), "2026-10-22T10:00:00+00:00",
     "datetime"},
    {"include/1", include("ell"), "ell", "include"}
  ]

  defp pact(dir), do: PactEx.new("matchers-consumer", "matchers-provider", pact_dir: dir)

  defp read_pact(dir) do
    dir |> Path.join("matchers-consumer-matchers-provider.json") |> File.read!() |> JSON.decode!()
  end

  defp request_interaction(matcher) do
    HTTP.interaction("matcher in request body")
    |> HTTP.with_request(:post, "/things", body: %{"v" => matcher})
    |> HTTP.will_respond_with(201)
  end

  defp post(mock, value) do
    Req.post!(mock.url <> "/things", json: %{"v" => value}, retry: false)
  end

  defp run_request(dir, matcher, value) do
    Consumer.run(pact(dir), [request_interaction(matcher)], fn mock -> post(mock, value) end)
  end

  defp rules(dir, side, path) do
    [written] = read_pact(dir)["interactions"]
    get_in(written, [side, "matchingRules", "body", path, "matchers"])
  end

  describe "request-side matchers accept a different value that satisfies the rule" do
    for {name, matcher, value, expected} <- @request_cases do
      test name, %{tmp_dir: dir} do
        assert :ok =
                 run_request(dir, unquote(Macro.escape(matcher)), unquote(Macro.escape(value)))

        case unquote(Macro.escape(expected)) do
          :each_key ->
            assert [%{"match" => "eachKey", "rules" => [%{"match" => "regex"}]}] =
                     rules(dir, "request", "$.v")

          expected ->
            assert rules(dir, "request", "$.v") == expected
        end
      end
    end
  end

  describe "response-side matchers return the example" do
    for {name, matcher, example, match} <- @response_cases do
      test name, %{tmp_dir: dir} do
        interaction =
          HTTP.interaction("matcher in response body")
          |> HTTP.with_request(:get, "/things")
          |> HTTP.will_respond_with(200, body: %{"v" => unquote(Macro.escape(matcher))})

        assert :ok =
                 Consumer.run(pact(dir), [interaction], fn mock ->
                   resp = Req.get!(mock.url <> "/things", retry: false)
                   assert resp.body == %{"v" => unquote(Macro.escape(example))}
                 end)

        assert [%{"match" => unquote(match)} | _] = rules(dir, "response", "$.v")
      end
    end
  end

  # The mock server names the body path and the rule it enforced.
  defp assert_body_mismatch(result, text) do
    assert {:error, %MismatchError{mismatches: [mismatch]}} = result
    assert %{"type" => "request-mismatch", "mismatches" => [detail]} = mismatch
    assert %{"type" => "BodyMismatch", "path" => "$.v", "mismatch" => message} = detail
    assert message =~ text
  end

  describe "request-side matchers reject a value that breaks the rule" do
    test "regex/2 with a non-matching string", %{tmp_dir: dir} do
      dir
      |> run_request(regex("abc-123", "^abc-\\d+$"), "nope")
      |> assert_body_mismatch("to match")

      refute File.exists?(Path.join(dir, "matchers-consumer-matchers-provider.json"))
    end

    test "integer/1 with a string", %{tmp_dir: dir} do
      dir |> run_request(integer(1), "42") |> assert_body_mismatch("integer")
    end

    test "each_like/2 with fewer elements than min", %{tmp_dir: dir} do
      dir
      |> run_request(each_like("x", min: 2), ["only-one"])
      |> assert_body_mismatch("minimum size of 2")
    end
  end
end
