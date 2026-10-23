defmodule PactEx.Consumer.Apply do
  @moduledoc false

  # Turns a `PactEx.HTTP.Interaction` into native calls on a pact handle.
  #
  # Encoding rules:
  #   * binaries pass through, maps (matchers) are JSON-encoded, integers,
  #     floats and booleans are stringified (query and header values only);
  #   * query and header names may be binaries or atoms;
  #   * a list value becomes one native call per element, using its index;
  #   * a map or list body is JSON, a valid UTF-8 binary without NUL is text,
  #     any other binary is sent as binary;
  #   * each part (request or response) has one content type, chosen in this
  #     order: the explicit `:content_type`, the Content-Type header (name in
  #     any case; a string, or the "value" of a matcher; the first element of
  #     a list), then the default of the body type. It applies to every body
  #     type, so a map body with an XML Content-Type is an XML description;
  #   * the Content-Type header is always written as "Content-Type".
  #     pact_ffi adds the body's content type under that exact-case key, and
  #     a lowercase header would give the part two Content-Type entries.
  #     Two headers that differ only in case are rejected.

  alias PactEx.{Error, Native}
  alias PactEx.HTTP.{Interaction, Request, Response}

  @invalid_code -101
  @entry_point "PactEx.Consumer.start_mock_server/3"

  @doc """
  Checks that `interaction` can be applied, without calling the native library.
  """
  @spec validate(Interaction.t()) :: :ok | {:error, Error.t()}
  def validate(%Interaction{request: nil, description: description}) do
    {:error,
     invalid(
       "interaction #{inspect(description)} has no request, call PactEx.HTTP.with_request/4 first"
     )}
  end

  def validate(%Interaction{}), do: :ok

  @doc """
  Applies `interaction` to the pact handle `pact_ref`.

  A missing response defaults to status 200.
  """
  @spec interaction(reference(), Interaction.t()) :: :ok | {:error, Error.t()}
  def interaction(pact_ref, %Interaction{} = interaction) do
    with :ok <- validate(interaction) do
      handle = Native.new_interaction(pact_ref, interaction.description)
      response = interaction.response || %Response{status: 200}

      with :ok <- provider_states(handle, interaction.provider_states),
           :ok <- request(handle, interaction.request) do
        response(handle, response)
      end
    end
  end

  defp provider_states(handle, states) do
    each_ok(states, fn
      {name, nil} ->
        native(Native.given(handle, name))

      {name, params} ->
        with {:ok, json} <- encode_json(params, "provider state params") do
          native(Native.given_with_params(handle, name, json))
        end
    end)
  end

  defp request(handle, %Request{} = request) do
    with {:ok, path} <- value(request.path, "request path"),
         :ok <- native(Native.with_request(handle, request.method, path)),
         :ok <- query(handle, request.query),
         {:ok, headers} <- canonical_headers(request.headers, "request header"),
         :ok <- headers(handle, :request, headers) do
      body(handle, :request, request.body, content_type(request, headers), "request body")
    end
  end

  defp response(handle, %Response{} = response) do
    with {:ok, status} <- status(response.status),
         :ok <- native(Native.response_status(handle, status)),
         {:ok, headers} <- canonical_headers(response.headers, "response header"),
         :ok <- headers(handle, :response, headers) do
      body(handle, :response, response.body, content_type(response, headers), "response body")
    end
  end

  defp status(status) when is_integer(status), do: {:ok, Integer.to_string(status)}
  defp status(status) when is_binary(status), do: {:ok, status}
  defp status(other), do: {:error, invalid("unsupported response status: #{inspect(other)}")}

  defp query(handle, query) do
    each_ok(query, fn {name, values} ->
      with {:ok, name} <- name(name, "query parameter") do
        indexed(values, "query parameter #{inspect(name)}", fn index, value ->
          native(Native.with_query_parameter(handle, name, index, value))
        end)
      end
    end)
  end

  defp headers(handle, part, headers) do
    each_ok(headers, fn {name, values} ->
      with {:ok, name} <- name(name, "#{part} header") do
        indexed(values, "#{part} header #{inspect(name)}", fn index, value ->
          native(Native.with_header(handle, part, name, index, value))
        end)
      end
    end)
  end

  defp name(name, _label) when is_binary(name), do: {:ok, name}

  defp name(name, _label) when is_atom(name) and name not in [nil, true, false],
    do: {:ok, Atom.to_string(name)}

  defp name(other, label) do
    {:error,
     invalid("unsupported #{label} name: #{inspect(other)}, expected a string or an atom")}
  end

  defp indexed(values, label, fun) do
    values
    |> then(&if is_list(&1), do: &1, else: [&1])
    |> Enum.with_index()
    |> each_ok(fn {value, index} ->
      with {:ok, encoded} <- param_value(value, label), do: fun.(index, encoded)
    end)
  end

  # Query and header values: scalars are stringified.
  defp param_value(value, _label) when is_number(value) or is_boolean(value),
    do: {:ok, to_string(value)}

  defp param_value(value, label), do: value(value, label)

  # Turns header names into strings and writes any spelling of Content-Type
  # as "Content-Type". Returns a list of `{name, values}`.
  defp canonical_headers(headers, label) do
    headers
    |> Enum.reduce_while({:ok, []}, fn {name, values}, {:ok, acc} ->
      case name(name, label) do
        {:ok, name} -> {:cont, {:ok, [{canonical_name(name), values} | acc]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, acc} -> unique_content_type(Enum.reverse(acc), label)
      error -> error
    end
  end

  defp canonical_name(name) do
    if String.downcase(name) == "content-type", do: "Content-Type", else: name
  end

  defp unique_content_type(headers, label) do
    case Enum.count(headers, fn {name, _values} -> name == "Content-Type" end) do
      count when count > 1 ->
        {:error, invalid("#{label}s contain Content-Type more than once, with different case")}

      _ ->
        {:ok, headers}
    end
  end

  # An explicit `:content_type` wins, then the Content-Type header. `nil`
  # leaves the default of the body type.
  defp content_type(%{content_type: content_type}, _headers) when is_binary(content_type),
    do: content_type

  defp content_type(_part, headers) do
    Enum.find_value(headers, fn
      {"Content-Type", values} -> header_content_type(values)
      _other -> nil
    end)
  end

  defp header_content_type(values) do
    case List.wrap(values) do
      [value | _] when is_binary(value) -> value
      [%{"value" => value} | _] when is_binary(value) -> value
      _ -> nil
    end
  end

  defp body(_handle, _part, nil, _content_type, _label), do: :ok

  defp body(handle, part, body, content_type, label)
       when is_map(body) or is_list(body) do
    with {:ok, json} <- encode_json(body, label) do
      native(Native.with_body(handle, part, content_type || "application/json", json))
    end
  end

  defp body(handle, part, body, content_type, _label) when is_binary(body) do
    if String.valid?(body) and not String.contains?(body, <<0>>) do
      native(Native.with_body(handle, part, content_type || "text/plain", body))
    else
      native(
        Native.with_binary_body(handle, part, content_type || "application/octet-stream", body)
      )
    end
  end

  defp body(_handle, _part, other, _content_type, label) do
    {:error, invalid("unsupported #{label}: #{inspect(other)}, expected a binary, map or list")}
  end

  defp value(value, _label) when is_binary(value), do: {:ok, value}
  defp value(value, label) when is_map(value), do: encode_json(value, label)

  defp value(other, label) do
    {:error,
     invalid("unsupported #{label}: #{inspect(other)}, expected a binary or a matcher map")}
  end

  defp encode_json(term, label) do
    {:ok, JSON.encode!(term)}
  rescue
    error in [Protocol.UndefinedError, ArgumentError] ->
      {:error, invalid("cannot encode #{label} as JSON: #{Exception.message(error)}")}
  end

  @doc false
  @spec native(:ok | {:ok, term()} | {:error, map()}) :: :ok | {:ok, term()} | {:error, Error.t()}
  def native(:ok), do: :ok
  def native({:ok, _} = ok), do: ok
  def native({:error, error}), do: {:error, Error.from_native(error)}

  @doc false
  @spec each_ok(Enumerable.t(), (term() -> :ok | {:error, term()})) :: :ok | {:error, term()}
  def each_ok(enumerable, fun) do
    Enum.reduce_while(enumerable, :ok, fn item, :ok ->
      case fun.(item) do
        :ok -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp invalid(message) do
    %Error{function: @entry_point, code: @invalid_code, message: message}
  end
end
