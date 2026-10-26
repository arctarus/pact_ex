defmodule PactEx.Native.SchedulerTest do
  use ExUnit.Case, async: false

  alias PactEx.Native

  @calls 3_000
  @threshold_us 5_000

  # The time that the scheduler threads of `type` have spent out of sleep.
  defp busy(type) do
    :microstate_accounting
    |> :erlang.statistics()
    |> Enum.filter(&(&1.type == type))
    |> Enum.map(fn %{counters: counters} ->
      counters |> Map.values() |> Enum.sum() |> Kernel.-(counters.sleep)
    end)
    |> Enum.sum()
  end

  # Runs `fun` with microstate accounting on and returns the busy time it
  # added to the dirty IO schedulers, in perf_counter units.
  defp dirty_io_busy_during(fun) do
    previous = :erlang.system_flag(:microstate_accounting, true)
    on_exit(fn -> :erlang.system_flag(:microstate_accounting, previous) end)
    before = busy(:dirty_io_scheduler)
    fun.()
    busy(:dirty_io_scheduler) - before
  end

  test "the builder NIFs run on dirty IO schedulers" do
    pact = Native.new_pact("scheduler-consumer", "scheduler-provider")
    interaction = Native.new_interaction(pact, "scheduling")

    dirty =
      dirty_io_busy_during(fn ->
        for _ <- 1..@calls do
          :ok = Native.given(interaction, "a state")
          :ok = Native.with_body(interaction, :response, "text/plain", "pong")
          :ok = Native.with_request(interaction, "GET", "/ping")
        end
      end)

    # The counters are in raw perf_counter units, so convert them first. On
    # normal schedulers the loop adds no dirty IO time. Run dirty, it adds
    # about 20 ms, so this threshold has a 4x margin.
    dirty_us = :erlang.convert_time_unit(dirty, :perf_counter, :microsecond)
    assert dirty_us > @threshold_us
  end
end
