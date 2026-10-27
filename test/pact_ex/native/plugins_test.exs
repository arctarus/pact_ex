defmodule PactEx.Native.PluginsTest do
  # async: false. ExUnit runs the async modules first and the others after them,
  # so no other test sees the changed environment.
  use ExUnit.Case, async: false
  alias PactEx.Native

  setup do
    previous = System.get_env("PACT_PLUGIN_DIR")

    # A directory that does not exist: the driver then fails with
    # `Plugin directory "..." does not exist`, which does not name the plugin.
    # The test passes on any machine, whatever is in ~/.pact/plugins.
    missing =
      Path.join(System.tmp_dir!(), "pact_ex_no_plugins_#{System.unique_integer([:positive])}")

    System.put_env("PACT_PLUGIN_DIR", missing)

    on_exit(fn ->
      if previous,
        do: System.put_env("PACT_PLUGIN_DIR", previous),
        else: System.delete_env("PACT_PLUGIN_DIR")
    end)
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

    assert message =~ "pact-ex-no-such-plugin"

    # The failed load recorded no plugin, but the call still claims the one-way
    # cleanup. A second call does nothing.
    assert Native.cleanup_plugins(pact) == true
    assert Native.cleanup_plugins(pact) == false
  end

  test "using_plugin returns an error once the plugins of the pact were cleaned up" do
    pact = v4_pact()
    assert Native.cleanup_plugins(pact) == true

    assert {:error, %{function: "pactffi_using_plugin", code: 2, message: message}} =
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
