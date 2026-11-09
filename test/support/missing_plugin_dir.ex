defmodule PactEx.MissingPluginDir do
  @moduledoc """
  Points `PACT_PLUGIN_DIR` at a directory that does not exist. Test support
  only.

  The plugin driver then fails with `Plugin directory "..." does not exist`,
  which does not name the plugin, and the test passes on any machine, whatever
  is in `~/.pact/plugins`.
  """

  @doc """
  Sets the variable and returns a function that restores it. Call it from
  `setup`, in a module with `async: false` (the environment is global), and
  pass the result to `on_exit/1`:

      setup do
        on_exit(PactEx.MissingPluginDir.set())
      end
  """
  @spec set() :: (-> :ok)
  def set do
    previous = System.get_env("PACT_PLUGIN_DIR")

    missing =
      Path.join(System.tmp_dir!(), "pact_ex_no_plugins_#{System.unique_integer([:positive])}")

    System.put_env("PACT_PLUGIN_DIR", missing)

    fn ->
      if previous,
        do: System.put_env("PACT_PLUGIN_DIR", previous),
        else: System.delete_env("PACT_PLUGIN_DIR")
    end
  end
end
