defmodule PactEx.SyncMessage.Runner do
  @moduledoc false

  # Runs a sync message: plan everything, build the message on a pact handle,
  # generate its contents, call the function and write the pact. With a
  # transport, a plugin mock server runs around the function and decides
  # whether the pact is written. See `PactEx.SyncMessage.run/4`.
  #
  # Everything that can fail on the input is planned before the first native
  # call, so an invalid message never touches pact_ffi, and the native calls that
  # follow only send what was planned.

  alias PactEx.{Consumer, Error, MismatchError, MockServer, Native}
  alias PactEx.Consumer.Apply
  alias PactEx.{Pact, Plugin, PluginContents, SyncMessage}
  alias PactEx.SyncMessage.Generated

  @entry_point "PactEx.SyncMessage.run/4"

  @spec run(Pact.t(), SyncMessage.t(), (Generated.t() -> any()), keyword()) ::
          :ok | {:error, Error.t() | MismatchError.t()}
  def run(%Pact{} = pact, %SyncMessage{} = message, fun, opts) do
    transport = check_options!(opts)

    with {:ok, plan} <- plan(pact, message, transport) do
      pact_ref = Native.new_pact(pact.consumer, pact.provider)

      # Once the pact exists, every way out unloads the plugins. If `fun`
      # raises, the write below never runs.
      try do
        with {:ok, generated} <- build(pact, pact_ref, message, plan) do
          call(pact, pact_ref, generated, fun, plan.transport)
        end
      after
        Plugin.cleanup(pact_ref)
      end
    end
  end

  defp call(pact, pact_ref, generated, fun, nil) do
    fun.(generated)
    Apply.native(Native.pact_handle_write_file(pact_ref, pact.pact_dir, false))
  end

  # The mock server is stopped before the plugins are unloaded, which the
  # `after` of `run/4` does. The mismatches are read before it is stopped.
  defp call(pact, pact_ref, generated, fun, transport) do
    with {:ok, port} <-
           Apply.native(
             Native.create_mock_server(
               pact_ref,
               transport.host,
               transport.port,
               transport.name,
               transport.config
             )
           ) do
      mock = %MockServer{
        port: port,
        url: MockServer.build_url(transport.host, port),
        pact_dir: pact.pact_dir,
        pact_ref: pact_ref
      }

      address = MockServer.build_address(transport.host, port)

      try do
        fun.(%{generated | transport: %{port: port, address: address}})
        Consumer.finish(mock, @entry_point)
      after
        Native.cleanup_mock_server(port)
      end
    end
  end

  # -- Options ----------------------------------------------------------------

  # Without a transport, `:host`, `:port` and `:transport_config` are not used
  # and not checked. With one, a wrong type is a caller bug and raises, as a
  # port out of range does in `PactEx.Consumer.start_mock_server/3`.
  defp check_options!(opts) do
    case Keyword.fetch!(opts, :transport) do
      nil ->
        nil

      name when is_binary(name) ->
        %{
          name: name,
          host: host!(Keyword.fetch!(opts, :host)),
          port: port!(Keyword.fetch!(opts, :port)),
          config: config!(Keyword.fetch!(opts, :transport_config))
        }

      other ->
        bad_option!(:transport, "a binary or nil", other)
    end
  end

  defp host!(host) when is_binary(host), do: host
  defp host!(host), do: bad_option!(:host, "a binary", host)

  defp port!(port) when is_integer(port) and port in 0..65_535, do: port
  defp port!(port), do: bad_option!(:port, "an integer from 0 to 65535", port)

  defp config!(config) when is_nil(config) or is_map(config), do: config
  defp config!(config), do: bad_option!(:transport_config, "a map or nil", config)

  @spec bad_option!(atom(), String.t(), term()) :: no_return()
  defp bad_option!(option, expected, value) do
    raise ArgumentError, "option #{inspect(option)} must be #{expected}, got: #{inspect(value)}"
  end

  # -- Plan: validate and encode, without any native call ---------------------

  defp plan(pact, message, transport) do
    plugin_contents = message.plugin_contents

    with :ok <- check_spec(pact),
         :ok <- check_contents_present(message),
         :ok <-
           Apply.check_plugins_declared(
             plugin_contents != nil,
             pact.plugins,
             @entry_point,
             "the sync message"
           ),
         :ok <- Apply.check_plugins_unique(pact.plugins, @entry_point),
         {:ok, contents} <- plan_contents(message),
         {:ok, states} <- Apply.plan_states(message.provider_states, @entry_point),
         {:ok, transport} <- plan_transport(transport) do
      {:ok, %{contents: contents, states: states, transport: transport}}
    end
  end

  defp plan_transport(nil), do: {:ok, nil}
  defp plan_transport(%{config: nil} = transport), do: {:ok, transport}

  defp plan_transport(%{config: config} = transport) do
    with {:ok, json} <- Apply.plan_json(config, "option :transport_config", @entry_point) do
      {:ok, %{transport | config: json}}
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
    |> Apply.map_ok(fn {{response, type}, number} ->
      Apply.plan_body(response, type, "sync message response #{number}", @entry_point)
    end)
  end

  # -- Build: native calls that send what was planned -------------------------

  defp build(pact, pact_ref, message, plan) do
    with :ok <- Apply.native(Native.with_specification(pact_ref, pact.spec)),
         :ok <- Plugin.load_all(pact_ref, pact) do
      handle = Native.new_sync_message_interaction(pact_ref, message.description)

      with :ok <- Apply.given_states(handle, plan.states),
           :ok <- contents(handle, plan.contents) do
        generate(handle)
      end
    end
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

  defp invalid(message), do: Apply.invalid(message, @entry_point)
end
