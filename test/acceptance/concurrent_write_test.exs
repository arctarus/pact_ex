defmodule PactEx.Acceptance.ConcurrentWriteTest do
  use ExUnit.Case, async: true

  alias PactEx.HTTP

  @tag :tmp_dir
  test "parallel runs merge into one pact file", %{tmp_dir: dir} do
    pact = PactEx.new("concurrent-consumer", "concurrent-provider", pact_dir: dir)

    1..8
    |> Task.async_stream(
      fn n ->
        i =
          HTTP.interaction("req #{n}")
          |> HTTP.with_request(:get, "/r/#{n}")
          |> HTTP.will_respond_with(200)

        PactEx.Consumer.run(pact, [i], fn m -> Req.get!(m.url <> "/r/#{n}", retry: false) end)
      end,
      max_concurrency: 8,
      timeout: 30_000
    )
    |> Enum.each(fn {:ok, result} -> assert result == :ok end)

    written =
      dir
      |> Path.join("concurrent-consumer-concurrent-provider.json")
      |> File.read!()
      |> JSON.decode!()

    assert length(written["interactions"]) == 8

    assert written["interactions"] |> Enum.map(& &1["description"]) |> Enum.sort() ==
             Enum.sort(for n <- 1..8, do: "req #{n}")
  end
end
