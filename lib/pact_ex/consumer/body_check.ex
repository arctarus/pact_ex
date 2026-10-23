defmodule PactEx.Consumer.BodyCheck do
  @moduledoc false

  # Checks the text handed to `pactffi_with_body` under an XML or form type.
  #
  # PactEx does not predict what pact_ffi will do from the Elixir term. It
  # chooses ONE content type string (see `PactEx.Consumer.Apply`), passes that
  # exact string to pact_ffi, and checks the exact bytes it passes, using
  # pact_models and serde_json themselves for the content type, the sniffing
  # and the parse (`PactEx.Native`).
  #
  # With an XML or form-urlencoded content type, pact_ffi 0.5.12 does not send
  # the JSON as it is. It reads it as a description of the body. Some shapes
  # make pact_ffi panic, and a panic cannot unwind out of an `extern "C"`
  # function, so it aborts the whole VM. Others are silently turned into an
  # empty body or lose values. Each rule below follows a code path in
  # `pact_ffi-0.5.12/src/mock_server/` (`handles.rs` `process_xml`, `xml.rs`,
  # `form_urlencoded.rs`).
  #
  # The description rules take the JSON as serde_json renders it, and accept
  # every description that pact_ffi turns into a document without a panic and
  # without dropping data.

  @matcher_key "pact:matcher:type"
  @max_u64 18_446_744_073_709_551_615

  alias PactEx.Native

  @doc """
  Checks a body that pact_ffi reads as a description, before it reaches
  `with_body`. `kind` is `:xml` or `:form`, `text` is the exact string handed
  to `with_body`, and `origin` is `:encoded` for a map or list that PactEx
  turned into JSON, or `:text` for a string the caller wrote.

  This mirrors `process_body` (pact_ffi 0.5.12, `handles.rs`), which looks only
  at the body text here (the content type was already chosen by PactEx):

    1. pact_ffi sniffs the text (`detect_content_type_from_string`). Text that
       is not sniffed as JSON is a raw body and is sent as it is. That is fine
       for a string, but a map PactEx encoded would go out as its JSON text, so
       it is an error.
    2. Sniffed as JSON, the text is parsed with serde_json. XML ends up with an
       empty body when it does not parse into an object, and a form body
       panics, so a text that is not a JSON object is an error.
    3. Duplicate keys are an error (serde_json keeps the last one, other
       readers the first).
    4. The decoded object is checked as an XML or form description.

  The parse in step 2 is done by serde_json itself (`Native.json_text_shape/1`)
  and the sniffing by pact_models (`Native.detect_json/1`), not by Elixir code.
  """
  @spec check(:xml | :form, String.t(), :encoded | :text) :: :ok | {:error, String.t()}
  def check(kind, text, origin) do
    if Native.detect_json(text) do
      case Native.json_text_shape(text) do
        {:object, rendered} ->
          # `decode(text)` finds repeated keys, which serde_json hides. The
          # description is then checked as serde_json renders it, so numbers
          # such as -0 or 2^64 are what pact_ffi reads.
          with {:ok, _decoded} <- decode(text),
               {:ok, decoded} <- decode(rendered),
               do: validate(kind, decoded)

        :other ->
          {:error, "the JSON is not an object, so pact_ffi would build an empty body"}

        :invalid ->
          {:error,
           "the text looks like JSON to pact_ffi but is not valid JSON, " <>
             "and pact_ffi would drop it or panic"}

        :too_deep ->
          {:error,
           "the text looks like JSON to pact_ffi but is nested deeper than " <>
             "serde_json's limit of 128 levels, and pact_ffi would drop it or panic"}
      end
    else
      case origin do
        :text -> :ok
        :encoded -> {:error, "pact_ffi would not read this JSON as a description"}
      end
    end
  end

  @doc """
  Decodes `json`, failing when an object repeats a key at any depth.

  The error names the path of the object, for example
  `$.items[1]: the key "id" appears more than once`. The JSON is decoded as it
  is, so this sees what the encoder wrote, including structs with their own
  `JSON.Encoder` and atom, integer or string keys that collide.
  """
  @spec decode(String.t()) :: {:ok, term()} | {:error, String.t()}
  def decode(json) when is_binary(json) do
    decoders = [
      array_start: fn _old -> {0, [], []} end,
      array_push: &array_push/2,
      array_finish: fn {_count, items, issues}, old ->
        {{:node, Enum.reverse(items), issues}, old}
      end,
      object_start: fn _old -> {%{}, []} end,
      object_push: &object_push/3,
      object_finish: fn {map, issues}, old -> {{:node, map, issues}, old} end
    ]

    case JSON.decode(json, nil, decoders) do
      {decoded, nil, rest} ->
        with :ok <- trailing(rest), do: issues(decoded)

      {:error, reason} ->
        {:error, "not valid JSON: #{inspect(reason)}"}
    end
  end

  defp trailing(rest) do
    if Regex.match?(~r/\A[ \t\r\n]*\z/, rest),
      do: :ok,
      else: {:error, "not valid JSON: trailing characters"}
  end

  defp array_push(elem, {count, items, issues}) do
    {value, child_issues} = unwrap(elem)
    {count + 1, [value | items], prefix(child_issues, {:index, count}) ++ issues}
  end

  defp object_push(key, elem, {map, issues}) do
    {value, child_issues} = unwrap(elem)
    issues = prefix(child_issues, {:key, key}) ++ issues
    issues = if is_map_key(map, key), do: [{[], key} | issues], else: issues
    {Map.put(map, key, value), issues}
  end

  defp unwrap({:node, value, issues}), do: {value, issues}
  defp unwrap(scalar), do: {scalar, []}

  defp prefix(issues, segment),
    do: Enum.map(issues, fn {path, key} -> {[segment | path], key} end)

  defp issues(root) do
    case unwrap(root) do
      {value, []} ->
        {:ok, value}

      {_value, issues} ->
        {path, key} = issues |> Enum.reverse() |> hd()

        {:error,
         "#{format_path(path)}: the key #{inspect(key)} appears more than once in the " <>
           "same object, and JSON readers disagree on which one wins"}
    end
  end

  defp format_path(path) do
    Enum.reduce(path, "$", fn
      {:key, key}, acc -> acc <> "." <> key
      {:index, index}, acc -> "#{acc}[#{index}]"
    end)
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
