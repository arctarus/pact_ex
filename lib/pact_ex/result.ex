defmodule PactEx.Result do
  @moduledoc false

  # Helpers for functions that return `:ok | {:ok, value} | {:error, reason}`.
  # Both stop at the first error and return it as it is.

  @doc """
  Calls `fun` on every item. `fun` returns `:ok` or `{:error, reason}`.
  """
  @spec each_ok(Enumerable.t(), (term() -> :ok | {:error, term()})) :: :ok | {:error, term()}
  def each_ok(enumerable, fun) do
    Enum.reduce_while(enumerable, :ok, fn item, :ok ->
      case fun.(item) do
        :ok -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  @doc """
  Like `Enum.map/2`, for a function that returns `{:ok, value}` or
  `{:error, reason}`. Returns `{:ok, values}` in the order of the items.
  """
  @spec map_ok(Enumerable.t(), (term() -> {:ok, term()} | {:error, term()})) ::
          {:ok, [term()]} | {:error, term()}
  def map_ok(enumerable, fun) do
    enumerable
    |> Enum.reduce_while({:ok, []}, fn item, {:ok, acc} ->
      case fun.(item) do
        {:ok, value} -> {:cont, {:ok, [value | acc]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      error -> error
    end
  end
end
