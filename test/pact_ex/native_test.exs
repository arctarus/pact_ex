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

  defp bad_arg(value), do: Function.identity(value)
end
