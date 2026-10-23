defmodule PactEx.NativeTest do
  use ExUnit.Case, async: true

  test "NIF loads and reports the pinned pact_ffi version" do
    assert PactEx.Native.version() == "0.5.12"
  end

  describe "content_type_kind/1" do
    test "classifies the types pact_ffi branches on" do
      assert PactEx.Native.content_type_kind("application/xml") == :xml
      assert PactEx.Native.content_type_kind("text/foo+xml; charset=utf-8") == :xml
      assert PactEx.Native.content_type_kind("application/x-www-form-urlencoded") == :form
      assert PactEx.Native.content_type_kind("application/json") == :json
      assert PactEx.Native.content_type_kind("application/xml+json") == :json
      assert PactEx.Native.content_type_kind("text/plain") == :other
      assert PactEx.Native.content_type_kind("image/svg+xml") == :other
    end

    test "returns :invalid for what mime cannot parse, including NUL bytes" do
      for ct <- [
            "",
            "nonsense",
            "application/xml ",
            "application/json; charset",
            "application/json,",
            "application/xml; charset",
            "application/xml\0",
            "app\0lication/xml"
          ] do
        assert PactEx.Native.content_type_kind(ct) == :invalid, inspect(ct)
      end
    end

    test "raises ArgumentError for anything that is not a UTF-8 string" do
      for bad <- [nil, :xml, 1, ~c"application/xml", <<255, 254>>] do
        assert_raise ArgumentError, fn -> PactEx.Native.content_type_kind(bad_arg(bad)) end
      end
    end
  end

  describe "detect_json/1" do
    test "follows pact_models' sniffing of the text" do
      for text <- [~s({"a":1}), "[1]", "123 items", "1=a&2=b", "null_flag=1", "true", ""] do
        assert PactEx.Native.detect_json(text) == (text != ""), inspect(text)
      end

      for text <- ["<a/>", ~s(<?xml version="1.0"?><a/>), "a=1", ~s({"-a":1}), ~s({"":1})] do
        refute PactEx.Native.detect_json(text), inspect(text)
      end
    end

    # The rules the README states: the regex is anchored at the start only, and
    # looks at a short prefix.
    test "matches only the prefix pact_models' regex asks for" do
      sniffed = [
        # Unicode whitespace (a no-break space, U+2003) may come first.
        "\u00A0{}",
        "\u2003 [",
        "{ }",
        "{\n}",
        ~s({ "a),
        ~s({"a b":1}),
        ~s({"\u00E9":1}),
        "[",
        "[ not json",
        ~s("),
        ~s("abc),
        ~s("a b"),
        "007",
        "false"
      ]

      for text <- sniffed, do: assert(PactEx.Native.detect_json(text), inspect(text))

      not_sniffed = [
        # A BOM is not whitespace.
        "\uFEFF{}",
        "x{}",
        "{",
        "{1}",
        ~s({"":1}),
        ~s({"-":1}),
        ~s({ "}),
        "-1",
        "x1",
        "\u0661",
        "True",
        "nul"
      ]

      for text <- not_sniffed, do: refute(PactEx.Native.detect_json(text), inspect(text))
    end

    test "a NUL byte is just text" do
      refute PactEx.Native.detect_json("a\0b")
      assert PactEx.Native.detect_json("{\"a\":\"x\0\"}")
    end

    test "raises ArgumentError for anything that is not a UTF-8 string" do
      for bad <- [nil, :json, 1, ~c"{}", <<255, 254>>] do
        assert_raise ArgumentError, fn -> PactEx.Native.detect_json(bad_arg(bad)) end
      end
    end
  end

  describe "json_text_shape/1" do
    test "returns the object as serde_json renders it" do
      assert {:object, rendered} = PactEx.Native.json_text_shape(~s({"a":1,"a":2}))
      assert JSON.decode!(rendered) == %{"a" => 2}

      assert {:object, "{\"a\":-0.0,\"b\":2.0,\"c\":1.8446744073709552e+19}"} =
               PactEx.Native.json_text_shape(~s({"a":-0,"b":2e0,"c":18446744073709551616}))
    end

    test "returns :other for JSON that is not an object" do
      for text <- ["[1]", "123", ~s("x"), "null", "true"] do
        assert PactEx.Native.json_text_shape(text) == :other, text
      end
    end

    test "returns :invalid for text serde_json cannot parse, including NUL" do
      for text <- ["", "1=a&2=b", "{", ~s({"a":1} x), "a\0b", ~s({"a":[1,]})] do
        assert PactEx.Native.json_text_shape(text) == :invalid, inspect(text)
      end
    end

    test "returns :too_deep for nesting beyond serde_json's limit of 128" do
      deep = String.duplicate("[", 200) <> String.duplicate("]", 200)
      unclosed = ~s({"a":) <> String.duplicate("[", 200)

      for text <- [~s({"a":#{deep}}), unclosed] do
        assert PactEx.Native.json_text_shape(text) == :too_deep, inspect(text, limit: 20)
      end
    end

    test "raises ArgumentError for anything that is not a UTF-8 string" do
      for bad <- [nil, :json, 1, ~c"{}", <<255, 254>>] do
        assert_raise ArgumentError, fn -> PactEx.Native.json_text_shape(bad_arg(bad)) end
      end
    end
  end

  defp bad_arg(value), do: Function.identity(value)
end
