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

    * `:query` - query parameters, a map. Defaults to `%{}`.
    * `:headers` - request headers, a map. Defaults to `%{}`.
    * `:body` - request body. Defaults to `nil`.
    * `:content_type` - content type of the body. Defaults to `nil`.

  Raises `ArgumentError` on unknown options, or if `:query` or `:headers` is
  not a map. Raises `FunctionClauseError` if `method` is not a string or an
  atom other than `nil`, `true` and `false`, or if `path` is not a string or a map.
  """
  @spec with_request(Interaction.t(), atom() | String.t(), String.t() | map(), keyword()) ::
          Interaction.t()
  def with_request(%Interaction{} = interaction, method, path, opts \\ [])
      when is_method(method) and (is_binary(path) or is_map(path)) do
    opts = Keyword.validate!(opts, query: %{}, headers: %{}, body: nil, content_type: nil)

    request = %Request{
      method: normalize_method(method),
      path: path,
      query: fetch_map!(opts, :query),
      headers: fetch_map!(opts, :headers),
      body: Keyword.fetch!(opts, :body),
      content_type: Keyword.fetch!(opts, :content_type)
    }

    %{interaction | request: request}
  end

  @doc """
  Sets the expected response. Calling it again replaces the previous response.

  `status` must be an integer from 100 to 599.

  ## Options

    * `:headers` - response headers, a map. Defaults to `%{}`.
    * `:body` - response body. Defaults to `nil`.
    * `:content_type` - content type of the body. Defaults to `nil`.

  Raises `ArgumentError` on unknown options, or if `:headers` is not a map.
  Raises `FunctionClauseError` if `status` is not an integer from 100 to 599.
  """
  @spec will_respond_with(Interaction.t(), pos_integer(), keyword()) :: Interaction.t()
  def will_respond_with(%Interaction{} = interaction, status, opts \\ [])
      when is_integer(status) and status in 100..599 do
    opts = Keyword.validate!(opts, headers: %{}, body: nil, content_type: nil)

    response = %Response{
      status: status,
      headers: fetch_map!(opts, :headers),
      body: Keyword.fetch!(opts, :body),
      content_type: Keyword.fetch!(opts, :content_type)
    }

    %{interaction | response: response}
  end

  defp fetch_map!(opts, key) do
    case Keyword.fetch!(opts, key) do
      value when is_map(value) ->
        value

      other ->
        raise ArgumentError, "option #{inspect(key)} must be a map, got: #{inspect(other)}"
    end
  end

  defp normalize_method(method) when is_atom(method),
    do: method |> Atom.to_string() |> String.upcase()

  defp normalize_method(method) when is_binary(method), do: String.upcase(method)
end
