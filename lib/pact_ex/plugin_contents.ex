defmodule PactEx.PluginContents do
  @moduledoc """
  A body that a Pact plugin builds from a description.

  Build it with `PactEx.Plugin.contents/2` and use it as the `:body` of a
  request or response. The pact needs the plugin that handles `content_type`
  (see `PactEx.using_plugin/3`).
  """

  @enforce_keys [:content_type, :contents]
  defstruct [:content_type, :contents]

  @type t :: %__MODULE__{content_type: String.t(), contents: map()}
end
