defmodule PactEx.SyncMessage.Runner do
  @moduledoc false

  # Runs a sync message: plan everything, build the message on a pact handle,
  # generate its contents, call the function and write the pact. See
  # `PactEx.SyncMessage.run/4`.
  #
  # Everything that can fail on the input is planned before the first native
  # call, so an invalid message never touches pact_ffi, and the native calls that
  # follow only send what was planned.

  alias PactEx.Consumer.Apply
  alias PactEx.{Error, Native, Pact, Plugin, PluginContents, SyncMessage}
  alias PactEx.SyncMessage.Generated

  @entry_point "PactEx.SyncMessage.run/4"
  @invalid_code -101

  @spec run(Pact.t(), SyncMessage.t(), (Generated.t() -> any()), keyword()) ::
          :ok | {:error, Error.t()}
  def run(%Pact{} = pact, %SyncMessage{} = message, fun, opts) do
    check_transport!(Keyword.fetch!(opts, :transport))

    with {:ok, plan} <- plan(pact, message) do
      pact_ref = Native.new_pact(pact.consumer, pact.provider)

      # Once the pact exists, every way out unloads the plugins. If `fun`
      # raises, the write below never runs.
      try do
        with {:ok, generated} <- build(pact, pact_ref, message, plan) do
          fun.(generated)
          Apply.native(Native.pact_handle_write_file(pact_ref, pact.pact_dir, false))
        end
      after
        Plugin.cleanup(pact_ref)
      end
    end
  end

  # Task 5 replaces this with the transport branch.
  defp check_transport!(nil), do: :ok
  defp check_transport!(_transport), do: raise(ArgumentError, "transport support lands in Task 5")

  # -- Plan: validate and encode, without any native call ---------------------

  defp plan(pact, message) do
    plugin_contents = message.plugin_contents

    with :ok <- check_spec(pact),
         :ok <- check_contents_present(message),
         :ok <- Apply.check_plugins_declared(plugin_contents != nil, pact.plugins, @entry_point),
         {:ok, contents} <- plan_contents(message),
         {:ok, states} <- plan_states(message.provider_states) do
      {:ok, %{contents: contents, states: states}}
    end
  end

  defp check_spec(%Pact{spec: :v4}), do: :ok

  defp check_spec(%Pact{spec: spec}) do
    {:error, invalid("sync messages need a V4 pact (spec: :v4), got #{inspect(spec)}.")}
  end

  # Plugin contents set the whole message, so the request and responses are
  # not looked at.
  defp check_contents_present(%SyncMessage{plugin_contents: %PluginContents{}}), do: :ok

  defp check_contents_present(%SyncMessage{request: request}) when request in [nil, ""] do
    {:error,
     invalid(
       "the sync message has no request, call PactEx.SyncMessage.with_request/3 with a " <>
         "value or PactEx.SyncMessage.with_plugin_contents/2"
     )}
  end

  # Each `with_body` on the response appends one response, so a `nil` response
  # would plan to no call and be dropped, and `fun` would get one fewer. An
  # empty one is a body no provider can be checked against.
  defp check_contents_present(%SyncMessage{responses: responses}) do
    case Enum.find_index(responses, fn {contents, _type} -> contents in [nil, ""] end) do
      nil ->
        :ok

      index ->
        {:error,
         invalid(
           "response #{index + 1} of the sync message has no contents, pass a value to " <>
             "PactEx.SyncMessage.will_respond_with/3"
         )}
    end
  end

  defp plan_contents(%SyncMessage{plugin_contents: %PluginContents{} = contents} = message) do
    with :ok <-
           Apply.check_plugin_content_type(
             contents,
             message.request_content_type,
             "sync message request",
             @entry_point
           ),
         :ok <- check_response_types(contents, message.responses),
         {:ok, json} <-
           Apply.plan_json(contents.contents, "sync message plugin contents", @entry_point) do
      {:ok, {:plugin, contents.content_type, json}}
    end
  end

  defp plan_contents(message) do
    with {:ok, request} <-
           Apply.plan_body(
             message.request,
             message.request_content_type,
             "sync message request",
             @entry_point
           ),
         {:ok, responses} <- plan_responses(message) do
      {:ok, {:bodies, request, responses}}
    end
  end

  defp check_response_types(contents, responses) do
    responses
    |> Enum.with_index(1)
    |> Apply.each_ok(fn {{_response, type}, number} ->
      Apply.check_plugin_content_type(
        contents,
        type,
        "sync message response #{number}",
        @entry_point
      )
    end)
  end

  defp plan_responses(message) do
    message.responses
    |> Enum.with_index(1)
    |> map_ok(fn {{response, type}, number} ->
      Apply.plan_body(response, type, "sync message response #{number}", @entry_point)
    end)
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

  # -- Build: native calls that send what was planned -------------------------

  defp build(pact, pact_ref, message, plan) do
    with :ok <- Apply.native(Native.with_specification(pact_ref, pact.spec)),
         :ok <- Plugin.load_all(pact_ref, pact) do
      handle = Native.new_sync_message_interaction(pact_ref, message.description)

      with :ok <- provider_states(handle, plan.states),
           :ok <- contents(handle, plan.contents) do
        generate(handle)
      end
    end
  end

  defp provider_states(handle, states) do
    Apply.each_ok(states, fn
      {name, nil} -> Apply.native(Native.given(handle, name))
      {name, json} -> Apply.native(Native.given_with_params(handle, name, json))
    end)
  end

  defp contents(handle, {:plugin, type, json}),
    do: Apply.native(Native.interaction_contents(handle, :request, type, json))

  defp contents(handle, {:bodies, request, responses}) do
    with :ok <- body(handle, :request, request) do
      Apply.each_ok(responses, &body(handle, :response, &1))
    end
  end

  defp body(_handle, _part, nil), do: :ok

  defp body(handle, part, {:text, type, text}),
    do: Apply.native(Native.with_body(handle, part, type, text))

  defp body(handle, part, {:binary, type, binary}),
    do: Apply.native(Native.with_binary_body(handle, part, type, binary))

  defp generate(handle) do
    with {:ok, json} <- Apply.native(Native.sync_message_generate_contents(handle)) do
      {:ok, Generated.from_json(json)}
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
