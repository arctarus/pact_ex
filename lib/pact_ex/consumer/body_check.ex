defmodule PactEx.Consumer.BodyCheck do
  @moduledoc false

  # Checks a map or list body before it reaches `pactffi_with_body`.
  #
  # With an XML or form-urlencoded content type, pact_ffi 0.5.12 does not send
  # the JSON as it is. It reads it as a description of the body. Some shapes
  # make pact_ffi panic, and a panic cannot unwind out of an `extern "C"`
  # function, so it aborts the whole VM. Others are silently turned into an
  # empty body or lose values. Each rule below follows a code path in
  # `pact_ffi-0.5.12/src/mock_server/` (`handles.rs` `process_xml`, `xml.rs`,
  # `form_urlencoded.rs`).
  #
  # The validator takes the JSON as pact_ffi reads it (the decoded body), and
  # it accepts every description that pact_ffi turns into a document without
  # a panic and without dropping data.

  @matcher_key "pact:matcher:type"
  @max_u64 18_446_744_073_709_551_615

  alias PactEx.Native

  @doc """
  Says how pact_ffi treats a map or list body: `:xml` (description of an XML
  document), `:form` (description of a form body), or `:other` (JSON or raw).

  This follows the real selection in `pactffi_with_body` and `process_body`
  (pact_ffi 0.5.12, `handles.rs`), with the parsing and the type checks done
  by pact_models through `PactEx.Native.content_type_kind/1`:

    1. `chosen` is the content type passed to `with_body`. If pact_ffi parses
       it, it is used. This holds even when the header says otherwise.
    2. If `chosen` does not parse, pact_ffi ignores it and uses the hint: the
       first value of the part's `Content-Type` header, if that parses
       (`calc_content_type` in pact_models, `.ok()` on the parse).
    3. If neither parses, pact_ffi detects the type from the body. A JSON
       body (always the case here) is neither XML nor form.
    4. With a parsed type, the branches are tried in this order: JSON, XML,
       form. So `application/xml+json` is JSON.

  `header` is the first `Content-Type` header value, or `nil`.
  """
  @spec kind(String.t() | nil, String.t() | nil) :: :xml | :form | :other
  def kind(chosen, header) do
    case classify(chosen) do
      :invalid -> header |> classify() |> to_kind()
      parsed -> to_kind(parsed)
    end
  end

  defp to_kind(kind) when kind in [:xml, :form], do: kind
  defp to_kind(_json_other_or_invalid), do: :other

  # A string that is not UTF-8 cannot reach the NIF. pact_ffi could not read it
  # either (`convert_cstr` fails), so it is as good as invalid.
  defp classify(content_type) when is_binary(content_type) do
    if String.valid?(content_type), do: Native.content_type_kind(content_type), else: :invalid
  end

  defp classify(_nil), do: :invalid

  @doc """
  Looks for two map keys that become the same JSON key, at any depth, in maps
  and lists.

  `JSON.encode!/1` writes both (`%{:a => 1, "a" => 2}` gives `{"a":1,"a":2}`).
  Elixir's decoder keeps the first, serde_json in pact_ffi keeps the last, so
  the two would read different bodies. Returns `{:error, reason}` with the path
  of the map.
  """
  @spec key_collision(term()) :: :ok | {:error, String.t()}
  def key_collision(term), do: collision(term, "$")

  defp collision(map, path) when is_map(map) and not is_struct(map) do
    keyed = for {key, value} <- map, do: {key_string(key), value}

    with :ok <- duplicate(keyed, path) do
      keyed
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.find_value(:ok, fn {key, value} ->
        case collision(value, path <> "." <> key_label(key)) do
          :ok -> nil
          error -> error
        end
      end)
    end
  end

  defp collision(list, path) when is_list(list) do
    list
    |> Enum.with_index()
    |> Enum.find_value(:ok, fn {item, index} ->
      case collision(item, "#{path}[#{index}]") do
        :ok -> nil
        error -> error
      end
    end)
  end

  defp collision(_scalar, _path), do: :ok

  defp key_label(key) when is_binary(key), do: key
  defp key_label(key), do: inspect(key)

  defp duplicate(keyed, path) do
    keyed
    |> Enum.frequencies_by(&elem(&1, 0))
    |> Enum.sort()
    |> Enum.find_value(:ok, fn
      {key, count} when count > 1 and is_binary(key) ->
        {:error,
         "#{path}: the key #{inspect(key)} appears #{count} times once converted to a " <>
           "string (for example as an atom and as a string), and JSON readers disagree " <>
           "on which one wins"}

      _other ->
        nil
    end)
  end

  # The string `JSON.encode!/1` writes for a key. A key that cannot be encoded
  # gets a unique term, so it never counts as a duplicate; the encoder reports
  # it later.
  defp key_string(key) do
    [string] = %{key => 0} |> JSON.encode!() |> JSON.decode!() |> Map.keys()
    string
  rescue
    _error -> make_ref()
  end

  @doc """
  Checks the decoded JSON `body` for `kind`. Returns `{:error, reason}` with a
  message that names the path of the first problem.
  """
  @spec validate(:xml | :form | :other, term()) :: :ok | {:error, String.t()}
  def validate(:xml, %{"root" => root}) when is_map(root), do: node(root, "$.root", :root)

  def validate(:xml, %{"root" => _}),
    do: {:error, ~s(the "root" key must be a map describing the root element)}

  def validate(:xml, body) when is_map(body),
    do: {:error, ~s(the map has no "root" key, so pact_ffi would build an empty document)}

  def validate(:xml, _body),
    do: {:error, ~s(an XML description must be a map with a "root" key, not a list)}

  def validate(:form, body) when is_map(body) do
    Enum.reduce_while(body, :ok, fn {key, value}, :ok ->
      case form_field(key, value) do
        :ok -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  def validate(:form, _body),
    do: {:error, "a form description must be a map, so pact_ffi would build an empty body"}

  def validate(:other, _body), do: :ok

  # -- XML (xml.rs `create_element_from_json`) --------------------------------

  defp node(object, path, position) do
    with :ok <- examples(object, path, position), do: shape(object, path, position)
  end

  # xml.rs:200-ish: `Number(val) => val.as_u64().unwrap()`, for every child.
  defp examples(%{"examples" => n}, _path, :child) when is_integer(n) and n in 0..@max_u64,
    do: :ok

  defp examples(%{"examples" => n}, path, :child) when is_number(n),
    do: {:error, ~s(#{path}: "examples" must be an integer from 0 to #{@max_u64}, got #{n})}

  defp examples(_object, _path, _position), do: :ok

  # The order of the clauses is the order of the checks in pact_ffi: matcher
  # first, then text, then named element.
  defp shape(%{@matcher_key => _} = object, path, _position) do
    case Map.fetch(object, "value") do
      {:ok, %{"name" => _} = value} ->
        element(value, path <> ".value")

      {:ok, %{}} ->
        {:error, ~s(#{path}.value: a matcher element needs a "name")}

      {:ok, _other} ->
        {:error, ~s(#{path}.value: must be a map with a "name")}

      :error ->
        {:error, ~s(#{path}: has "#{@matcher_key}" but no "value")}
    end
  end

  defp shape(%{"content" => _}, path, :root),
    do:
      {:error, "#{path}: the root cannot be a text node, pact_ffi would build an empty document"}

  defp shape(%{"content" => _}, _path, :child), do: :ok
  defp shape(%{"name" => _} = object, path, _position), do: element(object, path)

  defp shape(_object, path, _position) do
    {:error,
     ~s|#{path}: not an element {"name": ...}, a text node {"content": ...} | <>
       ~s|or a matcher element {"#{@matcher_key}": ..., "value": {"name": ...}}|}
  end

  defp element(object, path) do
    with :ok <- attributes(Map.get(object, "attributes"), path <> ".attributes") do
      children(Map.fetch(object, "children"), path <> ".children")
    end
  end

  # xml.rs `add_attributes`: a matcher without "value" hits `unwrap()`. An
  # "attributes" that is not a map is ignored.
  defp attributes(%{} = attributes, path) do
    Enum.find_value(attributes, :ok, fn
      {name, %{@matcher_key => _} = matcher} when not is_map_key(matcher, "value") ->
        {:error, ~s(#{path}["#{name}"]: attribute matcher without a "value")}

      _other ->
        nil
    end)
  end

  defp attributes(_ignored, _path), do: :ok

  # xml.rs: "children" that is present but not an array, or a child that is
  # not an object, is a `panic!`. That includes `"children": null`.
  defp children(:error, _path), do: :ok

  defp children({:ok, children}, path) when is_list(children) do
    children
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn
      {child, index}, :ok when is_map(child) ->
        case node(child, "#{path}[#{index}]", :child) do
          :ok -> {:cont, :ok}
          {:error, _} = error -> {:halt, error}
        end

      {_child, index}, :ok ->
        {:halt, {:error, "#{path}[#{index}]: a child must be a map"}}
    end)
  end

  defp children({:ok, _other}, path), do: {:error, "#{path}: must be a list of maps"}

  # -- Form (form_urlencoded.rs `convert_json_value_to_query_params`) ---------

  # pact_ffi first replaces each matcher by its "value", then keeps strings,
  # numbers and lists of those. It drops everything else without an error.
  # `process_object` removes the top-level keys that start with "pact:" before
  # the form is built.
  defp form_field("pact:" <> _ = key, _value) do
    {:error,
     "$.#{key}: pact_ffi drops keys that start with \"pact:\" from a form body " <>
       "(they are reserved for matchers and generators)"}
  end

  defp form_field(key, value), do: form_value(value, "$." <> key)

  defp form_value(value, path) do
    case resolve(value) do
      scalar when is_binary(scalar) or is_number(scalar) ->
        :ok

      list when is_list(list) ->
        list
        |> Enum.with_index()
        |> Enum.find_value(:ok, fn {item, index} ->
          item = resolve(item)

          if is_binary(item) or is_number(item),
            do: nil,
            else: form_error("#{path}[#{index}]", item)
        end)

      other ->
        form_error(path, other)
    end
  end

  # `process_matcher`: `arrayContains` (or `array-contains`) takes its value
  # from the list "variants". Any other matcher takes it from "value".
  defp resolve(%{@matcher_key => type} = matcher)
       when type in ["arrayContains", "array-contains"] do
    case Map.get(matcher, "variants") do
      variants when is_list(variants) -> Enum.map(variants, &resolve/1)
      _missing -> nil
    end
  end

  defp resolve(%{@matcher_key => _} = matcher), do: resolve(Map.get(matcher, "value"))
  defp resolve(value), do: value

  defp form_error(path, dropped) do
    {:error,
     "#{path}: #{describe(dropped)} is not a string, a number or a list of them, " <>
       "and pact_ffi drops it from the form body"}
  end

  defp describe(nil), do: "null (or a matcher without a value)"
  defp describe(value) when is_boolean(value), do: "the boolean #{value}"
  defp describe(value) when is_map(value), do: "a map"
  defp describe(value) when is_list(value), do: "a list"
end
