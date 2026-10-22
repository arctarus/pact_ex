defmodule PactEx.MatchersTest do
  use ExUnit.Case, async: true
  import PactEx.Matchers

  doctest PactEx.Matchers

  # Hides the value from the compile-time type checker, which would
  # otherwise warn about the deliberately invalid calls below.
  defp bad(value), do: Function.identity(value)

  describe "like/1" do
    test "wraps any value in a type matcher" do
      assert like(1) == %{"pact:matcher:type" => "type", "value" => 1}
      assert like(nil) == %{"pact:matcher:type" => "type", "value" => nil}
    end
  end

  describe "each_like/2" do
    test "wraps the example in a list with a minimum" do
      assert each_like(%{"a" => 1}) == %{
               "pact:matcher:type" => "type",
               "value" => [%{"a" => 1}],
               "min" => 1
             }

      assert each_like("x", min: 2)["min"] == 2
    end

    test "rejects a min below 1" do
      for min <- [0, -1] do
        assert_raise ArgumentError, ~r/min/, fn -> each_like("x", min: bad(min)) end
      end
    end

    test "rejects a non-integer min" do
      for min <- [1.5, "2", nil, :one] do
        assert_raise ArgumentError, ~r/min/, fn -> each_like("x", min: bad(min)) end
      end
    end

    test "rejects unknown options" do
      assert_raise ArgumentError, ~r/unknown keys \[:max\]/, fn ->
        each_like("x", max: 3)
      end
    end

    test "rejects options that are not a list" do
      assert_raise FunctionClauseError, fn -> each_like("x", bad(%{min: 1})) end
    end
  end

  describe "regex/2" do
    test "builds a regex matcher" do
      assert regex("male", "(male|female)") ==
               %{"pact:matcher:type" => "regex", "value" => "male", "regex" => "(male|female)"}
    end

    test "rejects a non-binary pattern" do
      for pattern <- [:male, 1, nil, ~r/male/] do
        assert_raise FunctionClauseError, fn -> regex("male", bad(pattern)) end
      end
    end
  end

  describe "each_key/2" do
    test "builds an eachKey matcher with a regex rule" do
      assert each_key(%{"happy" => true}, "(happy|ferocious)") == %{
               "pact:matcher:type" => "eachKey",
               "value" => %{"happy" => true},
               "rules" => [%{"pact:matcher:type" => "regex", "regex" => "(happy|ferocious)"}]
             }
    end

    test "rejects a non-binary pattern" do
      for pattern <- [:happy, 1, nil, ~r/happy/] do
        assert_raise FunctionClauseError, fn -> each_key(%{"a" => 1}, bad(pattern)) end
      end
    end
  end

  describe "integer/1" do
    test "builds an integer matcher" do
      assert integer(1) == %{"pact:matcher:type" => "integer", "value" => 1}
    end

    test "rejects a non-integer" do
      for value <- [1.5, "1", nil, :one] do
        assert_raise FunctionClauseError, fn -> integer(bad(value)) end
      end
    end
  end

  describe "decimal/1" do
    test "builds a decimal matcher from a float or an integer" do
      assert decimal(1.5) == %{"pact:matcher:type" => "decimal", "value" => 1.5}
      assert decimal(2) == %{"pact:matcher:type" => "decimal", "value" => 2}
    end

    test "rejects a non-number" do
      for value <- ["1.5", nil, :one] do
        assert_raise FunctionClauseError, fn -> decimal(bad(value)) end
      end
    end
  end

  describe "boolean/1" do
    test "builds a boolean matcher" do
      assert boolean(true) == %{"pact:matcher:type" => "boolean", "value" => true}
      assert boolean(false) == %{"pact:matcher:type" => "boolean", "value" => false}
    end

    test "rejects a non-boolean" do
      for value <- [nil, 1, 0, "true", :true_ish] do
        assert_raise FunctionClauseError, fn -> boolean(bad(value)) end
      end
    end
  end

  describe "datetime/2" do
    test "builds a datetime matcher" do
      assert datetime("2026-10-22T10:00:00Z", "yyyy-MM-dd'T'HH:mm:ssX") == %{
               "pact:matcher:type" => "datetime",
               "value" => "2026-10-22T10:00:00Z",
               "format" => "yyyy-MM-dd'T'HH:mm:ssX"
             }
    end

    test "rejects a non-binary value or format" do
      assert_raise FunctionClauseError, fn -> datetime(bad(1), "yyyy") end
      assert_raise FunctionClauseError, fn -> datetime("2026", bad(:yyyy)) end
      assert_raise FunctionClauseError, fn -> datetime(bad(nil), bad(nil)) end
    end
  end

  describe "include/1" do
    test "builds an include matcher" do
      assert include("ell") == %{"pact:matcher:type" => "include", "value" => "ell"}
    end

    test "rejects a non-binary substring" do
      for value <- [:ell, 1, nil] do
        assert_raise FunctionClauseError, fn -> include(bad(value)) end
      end
    end
  end

  describe "nesting" do
    test "matchers nest inside matchers" do
      assert like(%{"a" => integer(1)}) == %{
               "pact:matcher:type" => "type",
               "value" => %{"a" => %{"pact:matcher:type" => "integer", "value" => 1}}
             }

      assert each_like(like("x")) == %{
               "pact:matcher:type" => "type",
               "value" => [%{"pact:matcher:type" => "type", "value" => "x"}],
               "min" => 1
             }

      assert each_key(%{"id" => regex("a1", "[a-z]\\d")}, "id")["value"] ==
               %{
                 "id" => %{"pact:matcher:type" => "regex", "value" => "a1", "regex" => "[a-z]\\d"}
               }
    end

    test "results survive JSON encoding" do
      body =
        each_like(%{
          "id" => integer(1),
          "price" => decimal(9.5),
          "active" => boolean(true),
          "name" => regex("bob", "[a-z]+"),
          "tags" => each_like(like("x"), min: 2),
          "created" => datetime("2026-10-22", "yyyy-MM-dd"),
          "email" => include("@"),
          "attrs" => each_key(%{"happy" => true}, "(happy|ferocious)")
        })

      assert body |> JSON.encode!() |> JSON.decode!() == body
    end
  end
end
