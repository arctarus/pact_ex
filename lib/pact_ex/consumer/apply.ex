defmodule PactEx.Consumer.Apply do
  @moduledoc false

  # Turns a `PactEx.HTTP.Interaction` into native calls on a pact handle.
  #
  # Encoding rules:
  #   * binaries pass through, maps (matchers) are JSON-encoded;
  #   * a list value becomes one native call per element, using its index;
  #   * a map or list body is JSON, a valid UTF-8 binary without NUL is text,
  #     any other binary is sent as binary.

  alias PactEx.{Error, Native}
  alias PactEx.HTTP.{Interaction, Request, Response}

  @invalid_code -101

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
         :ok <- headers(handle, :request, request.headers) do
      body(handle, :request, request.body, request.content_type, "request body")
    end
  end

  defp response(handle, %Response{} = response) do
    with {:ok, status} <- status(response.status),
         :ok <- native(Native.response_status(handle, status)),
         :ok <- headers(handle, :response, response.headers) do
      body(handle, :response, response.body, response.content_type, "response body")
    end
  end

  defp status(status) when is_integer(status), do: {:ok, Integer.to_string(status)}
  defp status(status) when is_binary(status), do: {:ok, status}
  defp status(other), do: {:error, invalid("unsupported response status: #{inspect(other)}")}

  defp query(handle, query) do
    each_ok(query, fn {name, values} ->
      indexed(values, "query parameter #{inspect(name)}", fn index, value ->
        native(Native.with_query_parameter(handle, name, index, value))
      end)
    end)
  end

  defp headers(handle, part, headers) do
    each_ok(headers, fn {name, values} ->
      indexed(values, "#{part} header #{inspect(name)}", fn index, value ->
        native(Native.with_header(handle, part, name, index, value))
      end)
    end)
  end

  defp indexed(values, label, fun) do
    values
    |> List.wrap()
    |> Enum.with_index()
    |> each_ok(fn {value, index} ->
      with {:ok, encoded} <- value(value, label), do: fun.(index, encoded)
    end)
  end

  defp body(_handle, _part, nil, _content_type, _label), do: :ok

  defp body(handle, part, body, content_type, label) when is_map(body) or is_list(body) do
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

  defp native(:ok), do: :ok
  defp native({:error, error}), do: {:error, Error.from_native(error)}

  defp each_ok(enumerable, fun) do
    Enum.reduce_while(enumerable, :ok, fn item, :ok ->
      case fun.(item) do
        :ok -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp invalid(message) do
    %Error{function: "PactEx.Consumer.Apply.interaction/2", code: @invalid_code, message: message}
  end
end
