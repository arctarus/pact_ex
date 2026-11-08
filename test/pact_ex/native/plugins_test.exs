defmodule PactEx.Native.PluginsTest do
  # async: false. ExUnit runs the async modules first and the others after them,
  # so no other test sees the changed environment.
  use ExUnit.Case, async: false
  alias PactEx.Native

  # Loads plugins. The driver's 60 s startup timeout must fire first; see test_helper.exs.
  @moduletag timeout: 120_000

  setup do
    on_exit(PactEx.MissingPluginDir.set())
  end

  defp v4_pact do
    pact = Native.new_pact("native-plugin-consumer", "native-plugin-provider")
    :ok = Native.with_specification(pact, :v4)
    pact
  end

  test "loading a plugin that is not installed returns code 2 with a message" do
    pact = v4_pact()

    assert {:error, %{function: "pactffi_using_plugin", code: 2, message: message}} =
             Native.using_plugin(pact, "pact-ex-no-such-plugin", "9.9.9")

    assert String.starts_with?(
             message,
             "pact-ex-no-such-plugin 9.9.9: Could not load plugin - "
           )

    # The failed load recorded no plugin, but the call still claims the one-way
    # cleanup. A second call does nothing.
    assert Native.cleanup_plugins(pact) == true
    assert Native.cleanup_plugins(pact) == false
  end

  test "using_plugin returns an error once the plugins of the pact were cleaned up" do
    pact = v4_pact()
    assert Native.cleanup_plugins(pact) == true

    assert {:error, %{function: "pactffi_using_plugin", code: -103, message: message}} =
             Native.using_plugin(pact, "protobuf", "0.8.1")

    assert message =~ "already cleaned up"
  end

  test "the error message starts with the plugin name when there is no version" do
    pact = v4_pact()

    assert {:error, %{function: "pactffi_using_plugin", code: 2, message: message}} =
             Native.using_plugin(pact, "pact-ex-no-such-plugin", nil)

    assert String.starts_with?(message, "pact-ex-no-such-plugin: ")
    assert Native.cleanup_plugins(pact) == true
  end

  test "using_plugin rejects a NUL byte in the name and still names the plugin" do
    pact = v4_pact()

    assert {:error, %{function: "pactffi_using_plugin", code: -100, message: message}} =
             Native.using_plugin(pact, "a\0b", "1.0.0")

    assert String.starts_with?(message, "a\0b 1.0.0: ")
  end
end
