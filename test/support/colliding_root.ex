defmodule CollidingRoot do
  @moduledoc """
  Test support. A struct that derives `JSON.Encoder`, so a nested map with an
  atom key and a string key still collides in the JSON it writes. It lives
  here because protocols are consolidated before the tests are compiled.
  """

  @derive JSON.Encoder
  defstruct [:root]
end
