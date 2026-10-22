defmodule PactEx.Matchers do
  @moduledoc """
  Pact matchers.

  Each function returns a map in the pact_ffi "integration JSON" format. Put
  the map where you would put a plain value, in a body, header, query value or
  path. The mock server matches by rule instead of by equality, and the
  example value is what it returns to the consumer.

      import PactEx.Matchers

      %{
        "id" => integer(1),
        "name" => like("Ada"),
        "email" => regex("ada@example.com", ".+@.+"),
        "tags" => each_like(like("admin"), min: 1)
      }

  Matchers nest, and the results are plain maps that encode to JSON.
  """

  @type t :: %{required(String.t()) => term()}

  @doc """
  Matches any value of the same type as `value`.

      iex> PactEx.Matchers.like(1)
      %{"pact:matcher:type" => "type", "value" => 1}
  """
  @spec like(term()) :: t()
  def like(value), do: %{"pact:matcher:type" => "type", "value" => value}

  @doc """
  Matches a list in which every element looks like `value`.

  `value` is the example element. The list needs at least `:min` elements
  (default `1`). The example list repeats `value` `:min` times, because the
  mock server does not pad it and would reject a shorter example.

  Raises `ArgumentError` if `:min` is not a positive integer, or if `opts`
  has any key other than `:min`. Raises `FunctionClauseError` if `opts` is
  not a list.

      iex> PactEx.Matchers.each_like("x", min: 2)
      %{"pact:matcher:type" => "type", "value" => ["x", "x"], "min" => 2}
  """
  @spec each_like(term(), min: pos_integer()) :: t()
  def each_like(value, opts \\ [min: 1]) when is_list(opts) do
    min = opts |> Keyword.validate!(min: 1) |> Keyword.fetch!(:min)

    unless is_integer(min) and min > 0 do
      raise ArgumentError, "expected :min to be a positive integer, got: #{inspect(min)}"
    end

    %{"pact:matcher:type" => "type", "value" => List.duplicate(value, min), "min" => min}
  end

  @doc """
  Matches a string against the regular expression `pattern`.

  `value` is the example string. It should match `pattern`.

  `value` is typed `term()` and not guarded, because regex rules also apply to
  path and query values, and pact_ffi matches those on their string form.

      iex> PactEx.Matchers.regex("male", "(male|female)")
      %{"pact:matcher:type" => "regex", "value" => "male", "regex" => "(male|female)"}
  """
  @spec regex(term(), String.t()) :: t()
  def regex(value, pattern) when is_binary(pattern) do
    %{"pact:matcher:type" => "regex", "value" => value, "regex" => pattern}
  end

  @doc """
  Matches a map whose keys all match the regular expression `pattern`.

  `value` is the example map. Raises `FunctionClauseError` if it is not a map.

      iex> PactEx.Matchers.each_key(%{"happy" => true}, "(happy|ferocious)")
      %{
        "pact:matcher:type" => "eachKey",
        "value" => %{"happy" => true},
        "rules" => [%{"pact:matcher:type" => "regex", "regex" => "(happy|ferocious)"}]
      }
  """
  @spec each_key(map(), String.t()) :: t()
  def each_key(value, pattern) when is_map(value) and is_binary(pattern) do
    %{
      "pact:matcher:type" => "eachKey",
      "value" => value,
      "rules" => [%{"pact:matcher:type" => "regex", "regex" => pattern}]
    }
  end

  @doc """
  Matches any integer. `value` is the example.

      iex> PactEx.Matchers.integer(1)
      %{"pact:matcher:type" => "integer", "value" => 1}
  """
  @spec integer(integer()) :: t()
  def integer(value) when is_integer(value) do
    %{"pact:matcher:type" => "integer", "value" => value}
  end

  @doc """
  Matches any decimal number. `value` is the example and must be a float.

  Integers are rejected: pact_matching checks decimals with a float test, and
  an integer such as `2` encodes as `2`, which fails its own rule. Use
  `2.0`.

      iex> PactEx.Matchers.decimal(1.5)
      %{"pact:matcher:type" => "decimal", "value" => 1.5}
  """
  @spec decimal(float()) :: t()
  def decimal(value) when is_float(value) do
    %{"pact:matcher:type" => "decimal", "value" => value}
  end

  @doc """
  Matches any boolean. `value` is the example.

      iex> PactEx.Matchers.boolean(true)
      %{"pact:matcher:type" => "boolean", "value" => true}
  """
  @spec boolean(boolean()) :: t()
  def boolean(value) when is_boolean(value) do
    %{"pact:matcher:type" => "boolean", "value" => value}
  end

  @doc """
  Matches a date or time string in the given Java `DateTimeFormatter` `format`.

  `value` is the example string. It should follow `format`.

      iex> PactEx.Matchers.datetime("2026-10-22", "yyyy-MM-dd")
      %{"pact:matcher:type" => "datetime", "value" => "2026-10-22", "format" => "yyyy-MM-dd"}
  """
  @spec datetime(String.t(), String.t()) :: t()
  def datetime(value, format) when is_binary(value) and is_binary(format) do
    %{"pact:matcher:type" => "datetime", "value" => value, "format" => format}
  end

  @doc """
  Matches any string that contains `substring`. `substring` is also the example.

      iex> PactEx.Matchers.include("ell")
      %{"pact:matcher:type" => "include", "value" => "ell"}
  """
  @spec include(String.t()) :: t()
  def include(substring) when is_binary(substring) do
    %{"pact:matcher:type" => "include", "value" => substring}
  end
end
