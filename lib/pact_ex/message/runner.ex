defmodule PactEx.Message.Runner do
  @moduledoc false

  # Runs an async message: plan everything, build the message on a pact handle,
  # reify it, call the function and write the pact. See `PactEx.Message.run/4`.
  #
  # Everything that can fail on the input is planned before the first native
  # call, so an invalid message never touches pact_ffi, and the native calls that
  # follow only send what was planned.

  alias PactEx.Consumer.Apply
  alias PactEx.{Error, Message, Native, Pact, Plugin, PluginContents}
  alias PactEx.Message.Reified

  @entry_point "PactEx.Message.run/4"
  @invalid_code -101

  @spec run(Pact.t(), Message.t(), (Reified.t() -> any()), keyword()) ::
          :ok | {:error, Error.t()}
  def run(%Pact{} = pact, %Message{} = message, fun, []) do
    with {:ok, plan} <- plan(pact, message) do
      pact_ref = Native.new_pact(pact.consumer, pact.provider)

      # Once the pact exists, every way out unloads the plugins. If `fun`
      # raises, the write below never runs.
      try do
        with {:ok, reified} <- build(pact, pact_ref, message, plan) do
          fun.(reified)
          Apply.native(Native.pact_handle_write_file(pact_ref, pact.pact_dir, false))
        end
      after
        Plugin.cleanup(pact_ref)
      end
    end
  end

  # -- Plan: validate and encode, without any native call ---------------------

  defp plan(pact, message) do
    with :ok <- check_spec(pact),
         :ok <- check_contents_present(message.contents),
         :ok <-
           Apply.check_plugins_declared(
             match?(%PluginContents{}, message.contents),
             pact.plugins,
             @entry_point
           ),
         {:ok, contents} <- plan_contents(message),
         {:ok, states} <- plan_states(message.provider_states),
         {:ok, metadata} <- plan_metadata(message.metadata) do
      {:ok, %{contents: contents, states: states, metadata: metadata}}
    end
  end

  defp check_spec(%Pact{spec: :v4}), do: :ok

  defp check_spec(%Pact{spec: spec}) do
    {:error,
     invalid(
       "async messages need a V4 pact (spec: :v4), got #{inspect(spec)}. pact_ffi reifies " <>
         "a message of an older spec in a shape PactEx does not read."
     )}
  end

  defp check_contents_present(contents) when contents in [nil, ""] do
    {:error,
     invalid("the message has no contents, call PactEx.Message.with_contents/3 with a value")}
  end

  defp check_contents_present(_contents), do: :ok

  defp plan_contents(%Message{contents: %PluginContents{} = contents} = message) do
    with :ok <-
           Apply.check_plugin_content_type(
             contents,
             message.content_type,
             "message contents",
             @entry_point
           ),
         {:ok, json} <- Apply.plan_json(contents.contents, "message contents", @entry_point) do
      {:ok, {:plugin, contents.content_type, json}}
    end
  end

  defp plan_contents(message) do
    Apply.plan_body(message.contents, message.content_type, "message contents", @entry_point)
  end

  defp plan_states(states) do
    map_ok(states, fn
      {name, nil} ->
        {:ok, {name, nil}}

      {name, params} ->
        with {:ok, json} <-
               Apply.plan_json(params, "params of provider state #{inspect(name)}", @entry_point) do
          {:ok, {name, json}}
        end
    end)
  end

  defp plan_metadata(metadata) do
    map_ok(metadata, fn
      {key, value} when is_binary(key) ->
        with {:ok, json} <- Apply.plan_json(value, "metadata #{inspect(key)}", @entry_point) do
          {:ok, {key, json}}
        end

      {key, _value} ->
        {:error, invalid("unsupported metadata key: #{inspect(key)}, expected a string")}
    end)
  end

  # -- Build: native calls that send what was planned -------------------------

  defp build(pact, pact_ref, message, plan) do
    with :ok <- Apply.native(Native.with_specification(pact_ref, pact.spec)),
         :ok <- Plugin.load_all(pact_ref, pact) do
      handle = Native.new_message_interaction(pact_ref, message.description)

      with :ok <- provider_states(handle, plan.states),
           :ok <- contents(handle, plan.contents),
           :ok <- metadata(handle, plan.metadata) do
        reify(handle)
      end
    end
  end

  defp provider_states(handle, states) do
    Apply.each_ok(states, fn
      {name, nil} -> Apply.native(Native.given(handle, name))
      {name, json} -> Apply.native(Native.given_with_params(handle, name, json))
    end)
  end

  defp contents(handle, {:text, type, text}),
    do: Apply.native(Native.with_body(handle, :request, type, text))

  defp contents(handle, {:binary, type, binary}),
    do: Apply.native(Native.with_binary_body(handle, :request, type, binary))

  defp contents(handle, {:plugin, type, json}),
    do: Apply.native(Native.interaction_contents(handle, :request, type, json))

  # Metadata goes after the contents: `pactffi_interaction_contents` replaces
  # the metadata of an async message, so plugin contents would wipe it.
  defp metadata(handle, metadata) do
    Apply.each_ok(metadata, fn {key, json} ->
      Apply.native(Native.with_metadata(handle, key, json, :request))
    end)
  end

  defp reify(handle) do
    with {:ok, json} <- Apply.native(Native.message_reify(handle)) do
      {:ok, Reified.from_json(json)}
    end
  end

  # -- Helpers ----------------------------------------------------------------

  defp map_ok(enumerable, fun) do
    enumerable
    |> Enum.reduce_while({:ok, []}, fn item, {:ok, acc} ->
      case fun.(item) do
        {:ok, value} -> {:cont, {:ok, [value | acc]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      error -> error
    end
  end

  defp invalid(message) do
    %Error{function: @entry_point, code: @invalid_code, message: message}
  end
end
