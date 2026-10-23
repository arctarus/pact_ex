defmodule PactEx.AbortMatrixTest do
  use ExUnit.Case, async: false

  @moduledoc """
  No input may abort the VM.

  pact_ffi panics on some inputs, and a panic aborts the whole OS process, so
  each case runs in its own `mix run`. A case that aborts fails here with the
  panic text, and the suite keeps going. The child must exit 0 and print the
  outcome the case expects: the server started and answered, or `PactEx`
  returned a `-101` error.
  """

  alias PactEx.AbortCases

  @moduletag :abort_matrix
  @moduletag timeout: 600_000

  @script "test/support/abort_cases/run.exs"

  defp run_case(%{name: name}) do
    {output, status} =
      System.cmd("mix", ["run", "--no-compile", "--no-deps-check", @script],
        env: [{"MIX_ENV", "test"}, {"ABORT_CASE", name}],
        stderr_to_stdout: true
      )

    outcome =
      case Regex.run(~r/^ABORT_CASE_RESULT (.*)$/m, output) do
        [_, text] -> text
        nil -> nil
      end

    {status, outcome, output}
  end

  defp verdict(%{name: name, expect: expect}, {status, outcome, output}) do
    cond do
      status != 0 or output =~ "fatal runtime error" ->
        {name, "child exited #{status}:\n#{String.slice(output, -600, 600)}"}

      expect == :ok and outcome != ":ok" ->
        {name, "expected :ok, got #{inspect(outcome)}"}

      expect == :invalid and outcome != "{:error, -101}" ->
        {name, "expected -101, got #{inspect(outcome)}"}

      true ->
        nil
    end
  end

  for {group, _cases} <- AbortCases.groups() do
    test "no case aborts the VM: #{group}" do
      {_, cases} = Enum.find(AbortCases.groups(), &(elem(&1, 0) == unquote(group)))

      failures =
        cases
        |> Task.async_stream(&{&1, run_case(&1)},
          max_concurrency: max(System.schedulers_online() - 1, 2),
          timeout: 120_000,
          ordered: false
        )
        |> Enum.map(fn {:ok, {kase, result}} -> verdict(kase, result) end)
        |> Enum.reject(&is_nil/1)

      assert failures == [], Enum.map_join(failures, "\n", fn {n, why} -> "#{n}: #{why}" end)
    end
  end

  test "the case names are unique and every case is pinned to :ok or :invalid" do
    names = Enum.map(AbortCases.all(), & &1.name)
    assert names == Enum.uniq(names)

    loose =
      for %{name: name, expect: expect} <- AbortCases.all(),
          expect not in [:ok, :invalid],
          do: name

    assert loose == []
  end
end
