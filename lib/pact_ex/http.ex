defmodule PactEx.HTTP do
  @moduledoc """
  Builder functions for HTTP interactions.

  These functions only build data. Nothing reaches the native layer until
  the interaction is applied to a mock server.

      PactEx.HTTP.interaction("get user")
      |> PactEx.HTTP.given("user exists", %{"id" => 1})
      |> PactEx.HTTP.with_request(:get, "/users/1")
      |> PactEx.HTTP.will_respond_with(200, body: %{"id" => 1})
  """

  alias PactEx.HTTP.{Interaction, Request, Response}

  defguardp is_method(m) when (is_atom(m) and m not in [nil, true, false]) or is_binary(m)

  @doc """
  Starts an interaction with the given description.

  Raises `FunctionClauseError` if `description` is not a string.
  """
  @spec interaction(String.t()) :: Interaction.t()
  def interaction(description) when is_binary(description) do
    %Interaction{description: description}
  end

  @doc """
  Adds a provider state. States keep the order of the calls.

  `params` is an optional map of state parameters.

  Raises `FunctionClauseError` if `state` is not a string, or if `params` is
  neither a map nor `nil`.
  """
  @spec given(Interaction.t(), String.t(), map() | nil) :: Interaction.t()
  def given(%Interaction{} = interaction, state, params \\ nil)
      when is_binary(state) and (is_map(params) or is_nil(params)) do
    %{interaction | provider_states: interaction.provider_states ++ [{state, params}]}
  end

  @doc """
  Sets the expected request.

  `method` is an atom or a string and is stored upper-cased. `path` is a
  string or a matcher map. Calling it again replaces the previous request.

  ## Options

    * `:query` - query parameters. Defaults to `%{}`. See below.
    * `:headers` - request headers. Defaults to `%{}`. See below.
    * `:body` - request body. Defaults to `nil`.
    * `:content_type` - content type of the body. Defaults to `nil`.

  `:query` and `:headers` take a map, a keyword list or a list of
  `{name, value}` tuples. A name is a string or an atom. Values are as in a map
  (strings, numbers, booleans, matchers, or a list of them):

      query: %{"tag" => ["a", "b"], page: 2}
      query: [page: 2, tag: "a", tag: "b"]
      headers: [{"x-id", "1"}, accept: "application/json"]

  A map is kept as you wrote it. A list is turned into a map with string names.
  A name that repeats gets all its values, in order, so `[tag: "a", tag: "b"]`
  is `%{"tag" => ["a", "b"]}`. A list value counts as several values:
  `[tag: ["a", "b"], tag: "c"]` is `%{"tag" => ["a", "b", "c"]}`, and an empty
  list adds nothing (a name whose values are all empty is an error when the
  interaction is applied, as in a map). Query names are case-sensitive, so
  `"Tag"` and `"tag"` stay apart. Header names are not: in a list,
  `[{"Accept", "a"}, accept: "b"]` is `%{"Accept" => ["a", "b"]}`, with the
  first spelling kept. That includes `Content-Type`: a list merges its
  spellings into one header with several values, while a map with two
  spellings of it is an error when the interaction is applied. A map is never
  merged.

  A header name that is an atom is written as Req writes it: underscores
  become dashes and ASCII letters lower case, so `x_request_id: "1"` is the
  header `"x-request-id"` and `content_type: "text/plain"` is `Content-Type`.
  This holds for a map as well as for a list. A header name that is a string
  is used as it is (`"x_id"` stays `"x_id"`). Query names are not changed:
  `page_size: 2` is the parameter `"page_size"`.

  Raises `ArgumentError` on unknown options, or if `:query` or `:headers` is
  neither a map, a keyword list nor a list of `{name, value}` tuples (a name
  must be a string or an atom other than `nil`, `true` and `false`). Raises
  `FunctionClauseError` if `method` is not a string or an atom other than
  `nil`, `true` and `false`, or if `path` is not a string or a map.
  """
  @spec with_request(Interaction.t(), atom() | String.t(), String.t() | map(), keyword()) ::
          Interaction.t()
  def with_request(%Interaction{} = interaction, method, path, opts \\ [])
      when is_method(method) and (is_binary(path) or is_map(path)) do
    opts = Keyword.validate!(opts, query: %{}, headers: %{}, body: nil, content_type: nil)

    request = %Request{
      method: normalize_method(method),
      path: path,
      query: fetch_params!(opts, :query),
      headers: fetch_params!(opts, :headers),
      body: Keyword.fetch!(opts, :body),
      content_type: Keyword.fetch!(opts, :content_type)
    }

    %{interaction | request: request}
  end

  @doc """
  Sets the expected response. Calling it again replaces the previous response.

  `status` must be an integer from 100 to 599.

  ## Options

    * `:headers` - response headers: a map, a keyword list or a list of
      `{name, value}` tuples, as for `with_request/4`. Defaults to `%{}`.
    * `:body` - response body. Defaults to `nil`.
    * `:content_type` - content type of the body. Defaults to `nil`.

  Raises `ArgumentError` on unknown options, or if `:headers` is neither a map,
  a keyword list nor a list of `{name, value}` tuples. Raises
  `FunctionClauseError` if `status` is not an integer from 100 to 599.
  """
  @spec will_respond_with(Interaction.t(), 100..599, keyword()) :: Interaction.t()
  def will_respond_with(%Interaction{} = interaction, status, opts \\ [])
      when is_integer(status) and status in 100..599 do
    opts = Keyword.validate!(opts, headers: %{}, body: nil, content_type: nil)

    response = %Response{
      status: status,
      headers: fetch_params!(opts, :headers),
      body: Keyword.fetch!(opts, :body),
      content_type: Keyword.fetch!(opts, :content_type)
    }

    %{interaction | response: response}
  end

  # A map is kept as it is. A list of `{name, value}` pairs becomes a map with
  # string names. A repeated name gets all its values in order, and a list
  # value counts as several. Header names that differ only in case are one
  # name, and the first spelling is kept.
  defp fetch_params!(opts, key) do
    case Keyword.fetch!(opts, key) do
      value when is_map(value) ->
        value

      value when is_list(value) ->
        if pairs?(value), do: merge_pairs(value, key), else: invalid_params!(key, value)

      other ->
        invalid_params!(key, other)
    end
  end

  @doc false
  # The name of a header that is an atom, as Req writes it
  # (`Req.Fields`): underscores become dashes and ASCII letters lower case, so
  # `:x_request_id` is `"x-request-id"`. A string name is used as it is.
  @spec header_name(atom() | String.t()) :: String.t()
  def header_name(name) when is_binary(name), do: name

  def header_name(name) when is_atom(name),
    do: name |> Atom.to_string() |> String.replace("_", "-") |> String.downcase(:ascii)

  defp invalid_params!(key, value) do
    raise ArgumentError,
          "option #{inspect(key)} must be a map or a list of {name, value} tuples " <>
            "(a keyword list is one), where a name is a string or an atom, got: " <>
            inspect(value)
  end

  defp pairs?([]), do: true
  defp pairs?([{name, _value} | rest]), do: valid_name?(name) and pairs?(rest)
  defp pairs?(_other), do: false

  defp valid_name?(name) when is_binary(name), do: true
  defp valid_name?(name), do: is_atom(name) and name not in [nil, true, false]

  defp merge_pairs(pairs, key) do
    pairs
    |> Enum.reduce(%{}, fn {name, value}, acc ->
      {name, folded} = param_name(key, name)

      Map.update(acc, folded, {name, [value]}, fn {first, values} -> {first, [value | values]} end)
    end)
    |> Map.new(fn {_folded, {name, values}} -> {name, join_values(Enum.reverse(values))} end)
  end

  defp param_name(:headers, name) do
    name = header_name(name)
    {name, String.downcase(name)}
  end

  defp param_name(:query, name) do
    name = to_string(name)
    {name, name}
  end

  defp join_values([single]), do: single
  defp join_values(values), do: Enum.flat_map(values, &if(is_list(&1), do: &1, else: [&1]))

  defp normalize_method(method) when is_atom(method),
    do: method |> Atom.to_string() |> String.upcase()

  defp normalize_method(method) when is_binary(method), do: String.upcase(method)
end
