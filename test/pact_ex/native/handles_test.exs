defmodule PactEx.Native.HandlesTest do
  use ExUnit.Case, async: true
  alias PactEx.Native

  setup do
    pact = Native.new_pact("handles-consumer", "handles-provider")
    %{pact: pact, interaction: Native.new_interaction(pact, "an interaction")}
  end

  test "pact and interaction handles are resources", %{pact: pact, interaction: i} do
    assert is_reference(pact)
    assert is_reference(i)
  end

  test "with_specification accepts known versions", %{pact: pact} do
    assert Native.with_specification(pact, :v2) == :ok
    assert Native.with_specification(pact, :v3) == :ok
    assert Native.with_specification(pact, :v4) == :ok
  end

  test "with_specification rejects unknown atoms", %{pact: pact} do
    assert_raise ArgumentError, fn -> Native.with_specification(pact, :v5) end
  end

  test "with_specification rejects a non-atom spec", %{pact: pact} do
    assert_raise ArgumentError, fn -> Native.with_specification(pact, "v4") end
  end

  test "new_pact raises ArgumentError when an argument contains a NUL byte" do
    assert_raise ArgumentError, fn -> Native.new_pact("bad\0consumer", "provider") end
    assert_raise ArgumentError, fn -> Native.new_pact("consumer", "bad\0provider") end
  end

  test "new_interaction raises ArgumentError when the description contains a NUL byte", %{
    pact: pact
  } do
    assert_raise ArgumentError, fn -> Native.new_interaction(pact, "bad\0description") end
  end

  test "given and given_with_params succeed with valid input", %{interaction: i} do
    assert Native.given(i, "a user exists") == :ok
    assert Native.given_with_params(i, "a user exists", ~s({"id": 1})) == :ok
  end

  test "FFI error message is read in the same call that failed", %{interaction: i} do
    assert {:error, %{function: "pactffi_given_with_params", code: 2, message: message}} =
             Native.given_with_params(i, "a user exists", "not json")

    assert message =~ "expected"
  end

  test "strings with NUL bytes are rejected without calling the FFI", %{interaction: i} do
    assert {:error,
            %{function: "pactffi_given", code: -100, message: "argument contains a NUL byte"}} =
             Native.given(i, "bad\0state")
  end

  test "given_with_params rejects NUL bytes in the state or the params", %{interaction: i} do
    assert {:error, %{function: "pactffi_given_with_params", code: -100}} =
             Native.given_with_params(i, "bad\0state", ~s({"id": 1}))

    assert {:error,
            %{
              function: "pactffi_given_with_params",
              code: -100,
              message: "argument contains a NUL byte"
            }} = Native.given_with_params(i, "a user exists", ~s({"id": "bad\0"}))
  end
end
