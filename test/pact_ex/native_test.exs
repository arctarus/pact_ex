defmodule PactEx.NativeTest do
  use ExUnit.Case, async: true

  test "NIF loads and reports the pinned pact_ffi version" do
    assert PactEx.Native.version() == "0.5.12"
  end
end
