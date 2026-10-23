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

      assert message == "pactffi_with_request failed with code 1"
      assert length(String.split(message, "pactffi_with_request")) == 2
    end

    test "message/1 shows the code once when the native message already has it" do
      for {code, message} <- [
            {1, "pactffi_x failed with code 1"},
            {-100, "pactffi_x failed with code -100"},
            {2, "pactffi_x failed with code 2 (error message too long to read)"},
            {3, "pactffi_x failed with code 3: no such port"}
          ] do
        text = Exception.message(%Error{function: "pactffi_x", code: code, message: message})

        assert text == message
        assert length(String.split(text, "code #{code}")) == 2
      end
    end

    test "message/1 adds the code when the native message starts with the function but omits it" do
      message =
        Exception.message(%Error{function: "pactffi_x", code: 4, message: "pactffi_x: no pact"})

      assert message == "pactffi_x: no pact (code 4)"
    end

    test "message/1 does not take another code for this one" do
      message =
        Exception.message(%Error{
          function: "pactffi_x",
          code: 1,
          message: "pactffi_x failed with code 10"
        })

      assert message == "pactffi_x failed with code 10 (code 1)"
    end

    test "message/1 shows the code once for a PactEx input error" do
      message =
        Exception.message(%Error{
          function: "PactEx.Consumer.start_mock_server/3",
          code: -101,
          message: "unsupported request path: 42"
        })

      assert message ==
               "PactEx.Consumer.start_mock_server/3 failed with code -101: unsupported request path: 42"
    end

    test "can be raised with a message" do
      assert_raise Error, ~r/boom/, fn ->
        raise Error, function: "f", code: 1, message: "boom"
      end
    end

    test "raising with a bare message does not need a function or code" do
      assert_raise Error, "msg", fn -> raise Error, "msg" end
      assert_raise Error, "msg", fn -> raise Error, message: "msg" end
    end

    test "message/1 tolerates a missing function and message" do
      assert Exception.message(%Error{code: 3, message: "no function"}) == "no function"
      assert is_binary(Exception.message(%Error{}))
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
