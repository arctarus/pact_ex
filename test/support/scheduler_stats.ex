defmodule PactEx.SchedulerStats do
  @moduledoc """
  Reads scheduler busy time from microstate accounting. Test support only.
  """

  @doc """
  The time that the scheduler threads of `type` have spent out of sleep, in
  perf_counter units. Turn on `:microstate_accounting` first.
  """
  @spec busy(atom()) :: number()
  def busy(type) do
    :microstate_accounting
    |> :erlang.statistics()
    |> Enum.filter(&(&1.type == type))
    |> Enum.map(fn %{counters: counters} ->
      counters |> Map.values() |> Enum.sum() |> Kernel.-(counters.sleep)
    end)
    |> Enum.sum()
  end
end
