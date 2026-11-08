defmodule PactEx.Plugin do
  @moduledoc """
  Pact plugins: contents that a plugin builds, and the loading of plugins.

  Declare the plugins of a pact with `PactEx.using_plugin/3`. They are loaded
  when a mock server or a message test starts, and unloaded when it stops.

  A plugin that is not on disk is installed by the plugin driver, from the
  pact-plugins index on GitHub. That needs network access, and it has no
  timeout. `installed?/2` only looks at the plugin directory.
  """

  alias PactEx.Consumer.Apply
  alias PactEx.{Error, Native, Pact, PluginContents}

  @doc """
  Describes a body that a plugin builds.

  `content_type` picks the plugin, and `contents` is the description the plugin
  reads, for example the fields of a protobuf message. Use the value as the
  `:body` of a request or response. It is not a plain map body: it is passed to
  the plugin, which returns the body and its matching rules.

  An explicit `:content_type` option or `Content-Type` header on the same part
  must name the same media type as `content_type`.
  """
  @spec contents(String.t(), map()) :: PluginContents.t()
  def contents(content_type, contents) when is_binary(content_type) and is_map(contents) do
    %PluginContents{content_type: content_type, contents: contents}
  end

  @doc false
  # Loads the plugins of `pact` into the pact handle `pact_ref`, in order. Stops
  # at the first plugin that fails. The ones loaded before it stay loaded: call
  # `cleanup/1`. Internal: it takes a raw pact handle, and plugins loaded by hand
  # on `mock.pact_ref` would leak.
  @spec load_all(reference(), Pact.t()) :: :ok | {:error, Error.t()}
  def load_all(pact_ref, %Pact{plugins: plugins}) do
    Apply.each_ok(plugins, fn {name, version} ->
      Apply.native(Native.using_plugin(pact_ref, name, version))
    end)
  end

  @doc false
  # Releases the plugins loaded for the pact handle `pact_ref`. A plugin process
  # exits when no pact uses it any more. Calling it again for the same pact does
  # nothing, and so does a pact without plugins. Internal, like `load_all/2`.
  @spec cleanup(reference()) :: :ok
  def cleanup(pact_ref) do
    Native.cleanup_plugins(pact_ref)
    :ok
  end

  @doc """
  Returns `true` if the plugin `name` at `version` is in the plugin directory.

  The directory is `$PACT_PLUGIN_DIR`, or `~/.pact/plugins` when it is not set.
  The check is for `<name>-<version>/pact-plugin.json` in it.
  """
  @spec installed?(String.t(), String.t()) :: boolean()
  def installed?(name, version) when is_binary(name) and is_binary(version) do
    [plugin_dir(), "#{name}-#{version}", "pact-plugin.json"]
    |> Path.join()
    |> File.regular?()
  end

  defp plugin_dir do
    case System.get_env("PACT_PLUGIN_DIR") do
      dir when dir in [nil, ""] -> Path.join([System.user_home!(), ".pact", "plugins"])
      dir -> dir
    end
  end
end
