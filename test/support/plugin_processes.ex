defmodule PluginProcesses do
  @moduledoc """
  Checks that no protobuf plugin process is left running. Test support only.
  """

  @attempts 50
  @interval_ms 100

  @doc """
  Polls for up to 5 s. Returns `true` as soon as no `pact-protobuf-plugin` process runs,
  and `false` if one still runs after that.
  """
  @spec gone?() :: boolean()
  def gone? do
    Enum.any?(1..@attempts, fn _ ->
      Process.sleep(@interval_ms)
      no_process?()
    end)
  end

  # `pgrep` exits with 1 when nothing matches.
  defp no_process? do
    {_output, status} = System.cmd("pgrep", ["-f", "pact-protobuf-plugin"])
    status == 1
  end
end
