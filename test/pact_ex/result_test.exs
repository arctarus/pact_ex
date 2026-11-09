defmodule PactEx.ResultTest do
  use ExUnit.Case, async: true

  alias PactEx.Result

  describe "each_ok/2" do
    test "is :ok for an empty list and when every call is :ok" do
      assert :ok = Result.each_ok([], fn _ -> {:error, :never} end)
      assert :ok = Result.each_ok([1, 2], fn _ -> :ok end)
    end

    test "stops at the first error and returns it" do
      parent = self()

      assert {:error, :two} =
               Result.each_ok([1, 2, 3], fn item ->
                 send(parent, {:called, item})
                 if item == 2, do: {:error, :two}, else: :ok
               end)

      assert_received {:called, 1}
      assert_received {:called, 2}
      refute_received {:called, 3}
    end
  end

  describe "map_ok/2" do
    test "returns the values in the order of the items" do
      assert {:ok, [2, 4, 6]} = Result.map_ok([1, 2, 3], &{:ok, &1 * 2})
      assert {:ok, []} = Result.map_ok([], &{:ok, &1})
    end

    test "stops at the first error and returns it" do
      parent = self()

      assert {:error, :two} =
               Result.map_ok([1, 2, 3], fn item ->
                 send(parent, {:called, item})
                 if item == 2, do: {:error, :two}, else: {:ok, item}
               end)

      refute_received {:called, 3}
    end
  end
end
