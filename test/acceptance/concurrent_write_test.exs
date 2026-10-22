defmodule PactEx.Acceptance.ConcurrentWriteTest do
  use ExUnit.Case, async: true

  alias PactEx.HTTP

  @tag :tmp_dir
  test "parallel runs merge into one pact file", %{tmp_dir: dir} do
    pact = PactEx.new("concurrent-consumer", "concurrent-provider", pact_dir: dir)

    # Every run waits here after its request and before `run/4` writes the
    # pact, so all 8 writes start together instead of one after another.
    barrier = :atomics.new(1, [])

    1..8
    |> Task.async_stream(
      fn n ->
        i =
          HTTP.interaction("req #{n}")
          |> HTTP.with_request(:get, "/r/#{n}")
          |> HTTP.will_respond_with(200)

        PactEx.Consumer.run(pact, [i], fn m ->
          Req.get!(m.url <> "/r/#{n}", retry: false)
          await_all(barrier, 8)
        end)
      end,
      max_concurrency: 8,
      timeout: 30_000
    )
    |> Enum.each(fn {:ok, result} -> assert result == :ok end)

    written = PactFile.read!(dir, {"concurrent-consumer", "concurrent-provider"})

    assert length(written["interactions"]) == 8

    assert written["interactions"] |> Enum.map(& &1["description"]) |> Enum.sort() ==
             Enum.sort(for n <- 1..8, do: "req #{n}")
  end

  defp await_all(barrier, count) do
    :atomics.add(barrier, 1, 1)
    deadline = System.monotonic_time(:millisecond) + 5_000
    wait(barrier, count, deadline)
  end

  defp wait(barrier, count, deadline) do
    cond do
      :atomics.get(barrier, 1) == count ->
        :ok

      System.monotonic_time(:millisecond) > deadline ->
        flunk("runs did not all reach the barrier")

      true ->
        Process.sleep(1)
        wait(barrier, count, deadline)
    end
  end
end
