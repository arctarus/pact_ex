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
  #   * every JSON that PactEx encodes is decoded again with a decoder that
  #     fails on a repeated key, so structs, custom encoders and atom, integer
  #     or string keys that collide are caught on the exact bytes that are sent;
  #   * each part (request or response) gets ONE canonical content type string.
  #     The candidates are, in order, the explicit `:content_type`, the
  #     Content-Type header (a string, the first element of a list, or the
  #     "value" string of a matcher) and the default of the body type. Each is
  #     trimmed and the first one that pact_models can parse is used
  #     (`Native.content_type_kind/1`). That exact string is passed to
  #     `with_body`, so pact_ffi never falls back to the stored header, and
  #     the same string is classified to decide whether the body is checked;
  #   * when the canonical string came from a plain-string header, the header
  #     is written with that string, so header and body type cannot drift;
  #   * the Content-Type header is always written as "Content-Type".
  #     pact_ffi adds the body's content type under that exact-case key, and
  #     a lowercase header would give the part two Content-Type entries.
  #     Two headers that differ only in case are rejected;
  #   * a Content-Type header that pact_ffi would store as an empty list is
  #     rejected (see `check_content_type_header/3`): pact_ffi indexes its
  #     first element and aborts the VM when it is missing. An empty or
  #     whitespace-only element is rejected too, and so is a `[]` value for any
  #     header or query parameter (it would write nothing);
  #   * with an XML or form type, a body that pact_ffi reads as a description
  #     is checked by `PactEx.Consumer.BodyCheck` before any native call:
  #     pact_ffi panics (and aborts the VM) on some descriptions.
  #
  # `plan/1` does all of this without calling the native library (apart from
  # the pure content type and JSON helpers). `interaction/2` applies the plan.

  alias PactEx.{Error, Native}
  alias PactEx.Consumer.BodyCheck
  alias PactEx.HTTP
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

  def validate(%Interaction{} = interaction) do
    with {:ok, _request, _response} <- plan(interaction), do: :ok
  end

  @doc """
  Applies `interaction` to the pact handle `pact_ref`.

  A missing response defaults to status 200.
  """
  @spec interaction(reference(), Interaction.t()) :: :ok | {:error, Error.t()}
  def interaction(_pact_ref, %Interaction{request: nil} = interaction) do
    validate(interaction)
  end

  def interaction(pact_ref, %Interaction{} = interaction) do
    with {:ok, request_plan, response_plan} <- plan(interaction) do
      handle = Native.new_interaction(pact_ref, interaction.description)
      response = interaction.response || %Response{status: 200}

      with :ok <- provider_states(handle, interaction.provider_states),
           :ok <- request(handle, interaction.request, request_plan) do
        response(handle, response, response_plan)
      end
    end
  end

  # -- Plan: headers and body of each part, decided before any native call ----

  defp plan(%Interaction{description: description} = interaction) do
    response = interaction.response || %Response{status: 200}

    with :ok <-
           check_params(interaction.request.query, "request query parameter", description),
         {:ok, request_plan} <- plan_part(:request, description, interaction.request),
         {:ok, response_plan} <- plan_part(:response, description, response) do
      {:ok, request_plan, response_plan}
    end
  end

  defp plan_part(part, description, %{body: body} = struct) do
    with {:ok, headers} <- canonical_headers(struct.headers, "#{part} header"),
         :ok <- check_params(headers, "#{part} header", description),
         :ok <- check_content_type_header(headers, part, description) do
      case body do
        nil ->
          {:ok, %{headers: headers, body: nil}}

        body when is_map(body) or is_list(body) ->
          label = "#{part} body of interaction #{inspect(description)}"

          with {:ok, json, _decoded} <- encode_decoded(body, label),
               {:ok, {source, type, kind}} <- choose_type(struct, headers, "application/json"),
               :ok <- check_body(kind, json, :encoded, part, description) do
            {:ok, %{headers: with_type(headers, source, type), body: {:text, type, json}}}
          end

        body when is_binary(body) ->
          plan_binary(part, description, struct, headers, body)

        other ->
          {:error,
           invalid("unsupported #{part} body: #{inspect(other)}, expected a binary, map or list")}
      end
    end
  end

  # A Content-Type header that pact_ffi cannot use, for two reasons.
  #
  # `pactffi_with_header_v2` passes each header string through serde_json
  # (`from_integration_json_v2`). A JSON object whose "value" is `[]`, with or
  # without "pact:matcher:type", becomes `Either::Right([])`, and
  # `set_header` stores that list. A plain string, a number, an object without
  # "value" or with a non-array "value" always gives at least one value
  # (`parse_header` never returns an empty list). Matchers in an array keep
  # its length (`process_array`).
  #
  # 1. An empty Vec aborts. With a list, element `i` is a separate call with
  #    index `i`. A `Right` replaces the whole header, whatever the index, and
  #    a later element with index above 0 resizes the list to `i + 1` entries.
  #    So when the LAST element is empty the header ends as `[]`:
  #    `["a/b", %{"value" => []}]` is `[]`. (`[]` as a whole writes nothing.)
  #    `pactffi_with_body` evaluates `content_type()` on the part before it
  #    reads the content type PactEx passes, and pact_models indexes `v[0]` of
  #    the Content-Type header, so an empty list panics inside `extern "C"`
  #    and aborts the VM. That happens for a text body (map, list, string)
  #    even with an explicit `:content_type`. It does not happen for a binary
  #    body or no body (the mock server serves it and the pact file records
  #    `"Content-Type": []`), but the header is still rejected: it is
  #    meaningless, and other pact_models code that reads the content type of
  #    the recorded part may hit the same `v[0]`.
  #
  # 2. An empty element makes the part useless. When an empty element is not
  #    last, the list keeps its length and the element is stored as an empty
  #    string: `[%{"value" => []}, "text/plain"]` is `["", "text/plain"]`.
  #    A string that is empty or only whitespace is stored the same way.
  #    That does not abort, but on a request no real client sends such a
  #    header, so the mock server answers 500 and `run` returns a
  #    `MismatchError`. On a response the mock server serves it and the
  #    request still matches, but no provider can produce such a header. So an
  #    empty or blank element at ANY position is rejected, with a reason for
  #    each side (`unusable/1`).
  defp check_content_type_header(headers, part, description) do
    with {"Content-Type", values} <- List.keyfind(headers, "Content-Type", 0),
         {:ok, index, kind} <- empty_element(values) do
      {:error, invalid(empty_message(kind, part, description, element_label(values, index)))}
    else
      _ -> :ok
    end
  end

  defp empty_message(:list, part, description, label) do
    "#{part} header \"Content-Type\" of interaction #{inspect(description)} " <>
      "has #{label} that resolves to an empty list of values. " <>
      "A \"value\" of [] leaves the header without a content type or with an " <>
      "empty one: pact_ffi aborts the VM when it reads a missing one, and " <>
      "#{unusable(part)}. Give every element a string value."
  end

  defp empty_message(:blank, part, description, label) do
    "#{part} header \"Content-Type\" of interaction #{inspect(description)}: " <>
      "#{label} is empty or only whitespace. pact_ffi records it as an empty " <>
      "content type, and #{unusable(part)}. Give every element a non-blank string value."
  end

  # Why an empty Content-Type is useless, on each side.
  defp unusable(:request), do: "no request of this interaction can match it"

  defp unusable(:response),
    do: "the mock server would serve a meaningless header that no provider can produce"

  defp element_label(values, index) when is_list(values), do: "element #{index}"
  defp element_label(_value, _index), do: "the value"

  # The first element that resolves to an empty value, as `{:ok, index, kind}`.
  # A header that is not a list counts as one element. `kind` is `:list` for an
  # empty list of values and `:blank` for an empty or whitespace-only string.
  defp empty_element(values) when is_list(values) do
    values
    |> Enum.with_index()
    |> Enum.find_value(:none, fn {value, index} ->
      if kind = empty_kind(value), do: {:ok, index, kind}
    end)
  end

  defp empty_element(value) do
    if kind = empty_kind(value), do: {:ok, 0, kind}, else: :none
  end

  # A string is blank when it trims to nothing, as `choose_type/3` trims it.
  # Otherwise it can be JSON text for a matcher, which pact_ffi parses like
  # `Native.json_text_shape/1` does (whitespace, repeated keys and the nesting
  # limit are serde_json's). A matcher map is encoded and decoded first.
  defp empty_kind(value) when is_binary(value) do
    cond do
      String.trim(value) == "" -> :blank
      not String.valid?(value) -> nil
      true -> json_text_kind(value)
    end
  end

  defp empty_kind(value) when is_map(value) do
    case encode_decoded(value, "Content-Type header") do
      {:ok, _json, decoded} -> matcher_kind(decoded)
      {:error, _} -> nil
    end
  end

  defp empty_kind(_scalar), do: nil

  defp json_text_kind(text) do
    with {:object, rendered} <- Native.json_text_shape(text),
         {:ok, decoded} <- BodyCheck.decode(rendered) do
      matcher_kind(decoded)
    else
      _ -> nil
    end
  end

  # What a decoded `{"value": ...}` object stores: no value at all (`[]`), or a
  # blank string, alone or inside the array of values.
  defp matcher_kind(%{"value" => []}), do: :list
  defp matcher_kind(%{"value" => value}) when is_binary(value), do: blank_kind(value)

  defp matcher_kind(%{"value" => values}) when is_list(values),
    do: if(Enum.any?(values, &(is_binary(&1) and blank?(&1))), do: :blank)

  defp matcher_kind(_other), do: nil

  defp blank_kind(value), do: if(blank?(value), do: :blank)
  defp blank?(value), do: String.trim(value) == ""

  # Every header and query parameter is checked here, before any native call:
  # its name, and each of its values (as `indexed/3` will encode them). A `[]`
  # value is an error too: it would make no native call, so the parameter
  # would be dropped without a word.
  defp check_params(params, label, description) do
    each_ok(params, fn
      {name, []} ->
        {:error,
         invalid(
           "#{label} #{inspect(display_name(name))} of interaction #{inspect(description)} " <>
             "is an empty list of values, so it would be dropped without a word. " <>
             "Give it at least one value, or leave it out."
         )}

      {name, values} ->
        with {:ok, name} <- name(name, label) do
          indexed(values, "#{label} #{inspect(name)}", fn _index, _value -> :ok end)
        end
    end)
  end

  defp display_name(name) when is_atom(name) and name not in [nil, true, false],
    do: Atom.to_string(name)

  defp display_name(name), do: name

  defp plan_binary(part, description, struct, headers, body) do
    if String.valid?(body) and not String.contains?(body, <<0>>) do
      with {:ok, {source, type, kind}} <- choose_type(struct, headers, "text/plain"),
           :ok <- check_body(kind, body, :text, part, description) do
        {:ok, %{headers: with_type(headers, source, type), body: {:text, type, body}}}
      end
    else
      with {:ok, {source, type, _kind}} <-
             choose_type(struct, headers, "application/octet-stream") do
        {:ok, %{headers: with_type(headers, source, type), body: {:binary, type, body}}}
      end
    end
  end

  defp check_body(kind, text, origin, part, description) when kind in [:xml, :form] do
    case BodyCheck.check(kind, text, origin) do
      :ok ->
        :ok

      {:error, reason} ->
        {:error,
         invalid(
           "#{part} body of interaction #{inspect(description)} cannot be sent: #{reason}. " <>
             "With an XML or form-urlencoded content type pact_ffi reads a JSON body as " <>
             "a description of the body in its own format, not as JSON, and it can " <>
             "panic on a description of the wrong shape. Pass a string for a raw body."
         )}
    end
  end

  defp check_body(_kind, _text, _origin, _part, _description), do: :ok

  # The canonical content type of a part: the first candidate, trimmed, that
  # pact_models can parse. A candidate with a NUL byte is taken as it is, so
  # that the native call rejects it with its usual error. The default always
  # parses.
  defp choose_type(%{content_type: explicit}, headers, default) do
    candidates = [
      {:explicit, explicit},
      {:header, header_candidate(headers)},
      {:default, default}
    ]

    Enum.find_value(candidates, fn
      {source, candidate} when is_binary(candidate) ->
        type = String.trim(candidate)

        case classify(type) do
          :invalid -> nil
          kind -> {:ok, {source, type, kind}}
        end

      _no_candidate ->
        nil
    end)
  end

  defp classify(type) do
    cond do
      not String.valid?(type) -> :invalid
      String.contains?(type, <<0>>) -> :other
      true -> Native.content_type_kind(type)
    end
  end

  # The Content-Type header as a content type candidate: a string, the first
  # string of a list, or the "value" string of a matcher.
  defp header_candidate(headers) do
    Enum.find_value(headers, fn
      {"Content-Type", values} -> header_value(values)
      _other -> nil
    end)
  end

  defp header_value(values) do
    case List.wrap(values) do
      [value | _] when is_binary(value) -> value
      [%{"value" => value} | _] when is_binary(value) -> value
      _ -> nil
    end
  end

  # A plain-string Content-Type header that gave the canonical type is written
  # with it. In every other case the header stays as the caller wrote it.
  defp with_type(headers, :header, type) do
    Enum.map(headers, fn
      {"Content-Type", value} when is_binary(value) -> {"Content-Type", type}
      {"Content-Type", [first | rest]} when is_binary(first) -> {"Content-Type", [type | rest]}
      other -> other
    end)
  end

  defp with_type(headers, _source, _type), do: headers

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

  defp request(handle, %Request{} = request, plan) do
    with {:ok, path} <- value(request.path, "request path"),
         :ok <- native(Native.with_request(handle, request.method, path)),
         :ok <- query(handle, request.query),
         :ok <- headers(handle, :request, plan.headers) do
      body(handle, :request, plan.body)
    end
  end

  defp response(handle, %Response{} = response, plan) do
    with {:ok, status} <- status(response.status),
         :ok <- native(Native.response_status(handle, status)),
         :ok <- headers(handle, :response, plan.headers) do
      body(handle, :response, plan.body)
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

  # An atom header name is written like Req writes it (`HTTP.header_name/1`).
  defp header_name(name, _label) when is_atom(name) and name not in [nil, true, false],
    do: {:ok, HTTP.header_name(name)}

  defp header_name(name, label), do: name(name, label)

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
      case header_name(name, label) do
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

  defp body(_handle, _part, nil), do: :ok

  defp body(handle, part, {:text, type, text}),
    do: native(Native.with_body(handle, part, type, text))

  defp body(handle, part, {:binary, type, binary}),
    do: native(Native.with_binary_body(handle, part, type, binary))

  defp value(value, _label) when is_binary(value), do: {:ok, value}
  defp value(value, label) when is_map(value), do: encode_json(value, label)

  defp value(other, label) do
    {:error,
     invalid("unsupported #{label}: #{inspect(other)}, expected a binary or a matcher map")}
  end

  defp encode_json(term, label) do
    with {:ok, json, _decoded} <- encode_decoded(term, label), do: {:ok, json}
  end

  # Encodes once and decodes those bytes, failing on a repeated key. Returns
  # the bytes (what is sent) and the term decoded from them.
  defp encode_decoded(term, label) do
    json = JSON.encode!(term)

    case BodyCheck.decode(json) do
      {:ok, decoded} -> {:ok, json, decoded}
      {:error, reason} -> {:error, invalid("cannot encode #{label} as JSON: #{reason}")}
    end
  rescue
    error -> {:error, invalid("cannot encode #{label} as JSON: #{Exception.message(error)}")}
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
