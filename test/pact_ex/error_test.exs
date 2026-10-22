defmodule PactEx.ErrorTest do
  use ExUnit.Case, async: true

  alias PactEx.{Error, MismatchError}

  describe "PactEx.Error" do
    test "from_native/1 copies the native error map" do
      assert %Error{function: "pactffi_x", code: 3, message: "no such port"} =
               Error.from_native(%{function: "pactffi_x", code: 3, message: "no such port"})
    end

    test "message/1 names the function, the code and the message" do
      message = Exception.message(%Error{function: "pactffi_x", code: 3, message: "no such port"})
      assert message =~ "pactffi_x"
      assert message =~ "3"
      assert message =~ "no such port"
    end

    test "message/1 does not repeat the function name when the native message starts with it" do
      message =
        Exception.message(%Error{
          function: "pactffi_with_request",
          code: 1,
          message: "pactffi_with_request failed with code 1"
        })

      assert message == "pactffi_with_request failed with code 1 (code 1)"
      assert length(String.split(message, "pactffi_with_request")) == 2
    end

    test "can be raised with a message" do
      assert_raise Error, ~r/boom/, fn ->
        raise Error, function: "f", code: 1, message: "boom"
      end
    end

    test "from_native/1 requires function, code and message" do
      assert_raise FunctionClauseError, fn -> Error.from_native(Function.identity(%{})) end
    end
  end

  describe "PactEx.MismatchError" do
    test "message/1 lists each mismatch with its type, method and path" do
      error = %MismatchError{
        mismatches: [
          %{"type" => "missing-request", "method" => "GET", "path" => "/never"},
          %{"type" => "request-not-found", "method" => "POST", "path" => "/surprise"}
        ]
      }

      message = Exception.message(error)
      assert message =~ "missing-request GET /never"
      assert message =~ "request-not-found POST /surprise"
    end

    test "message/1 includes the detail of request mismatches" do
      error = %MismatchError{
        mismatches: [
          %{
            "type" => "request-mismatch",
            "method" => "POST",
            "path" => "/things",
            "mismatches" => [%{"type" => "BodyMismatch", "mismatch" => "name was different"}]
          }
        ]
      }

      message = Exception.message(error)
      assert message =~ "request-mismatch POST /things"
      assert message =~ "name was different"
    end

    test "message/1 tolerates mismatches without method or path" do
      message = Exception.message(%MismatchError{mismatches: [%{"type" => "mystery"}]})
      assert message =~ "mystery"
    end

    test "message/1 tolerates an empty list" do
      assert is_binary(Exception.message(%MismatchError{mismatches: []}))
    end

    test "defaults to no mismatches" do
      assert %MismatchError{mismatches: []} = %MismatchError{}
    end
  end
end
