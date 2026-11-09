if Code.ensure_loaded?(Plug.Router) do
  defmodule PactEx.Verifier.Endpoint do
    @moduledoc false

    # The internal HTTP endpoint that pact_verifier calls during a verification:
    # `POST /_pact/state` for provider states and `POST /_pact/messages` for
    # message providers. See `PactEx.Verifier`.
    #
    # A failed callback answers 422, never 5xx: pact_verifier retries a 5xx
    # state change up to 8 times with backoff, about 127 s per call. It also
    # drops the body of a failed state change, so the reason goes to the process
    # that called `verify/1` as `{:pact_ex_callback_error, ref, text}`, when
    # `report_to: {pid, ref}` is given.

    use Plug.Router

    @defaults %{state_handler: nil, message_providers: %{}, fallback: nil, report_to: nil}

    @impl Plug
    def init(opts), do: Map.merge(@defaults, Map.new(opts))

    @impl Plug
    def call(conn, opts), do: super(Plug.Conn.put_private(conn, :pact_ex_endpoint, opts), opts)

    plug(:match)
    plug(Plug.Parsers, parsers: [:json], pass: ["*/*"], json_decoder: JSON)
    plug(:dispatch)

    post "/_pact/state" do
      %{"state" => state, "params" => params, "action" => action} = conn.body_params
      opts = conn.private.pact_ex_endpoint

      case call_handler(opts.state_handler, [state, params || %{}, action(action)]) do
        {:ok, result} when result in [:ok, nil] -> json(conn, 200, %{})
        {:ok, {:ok, map}} when is_map(map) -> json(conn, 200, map)
        {:ok, {:error, reason}} -> fail(conn, opts, "state #{inspect(state)} (#{action})", reason)
        {:ok, other} -> fail(conn, opts, "state #{inspect(state)} (#{action})", unexpected(other))
        {:raised, reason} -> fail(conn, opts, "state #{inspect(state)} (#{action})", reason)
      end
    end

    post "/_pact/messages" do
      %{"description" => description} = conn.body_params
      opts = conn.private.pact_ex_endpoint
      states = provider_states(conn.body_params["providerStates"])

      case provider(opts, description) do
        nil ->
          report(opts, "no message provider for #{inspect(description)}")
          json(conn, 404, %{"error" => "no message provider for #{description}"})

        fun ->
          case call_handler(fun, [states]) do
            {:ok, result} -> send_message(conn, result)
            {:raised, reason} -> fail(conn, opts, "message #{inspect(description)}", reason)
          end
      end
    end

    match _ do
      json(conn, 404, %{"error" => "not found"})
    end

    # -- Callbacks --------------------------------------------------------------

    defp call_handler(nil, _args), do: {:ok, :ok}

    defp call_handler(fun, args) do
      {:ok, apply(fun, args)}
    catch
      kind, reason -> {:raised, Exception.format_banner(kind, reason, __STACKTRACE__)}
    end

    defp action("teardown"), do: :teardown
    defp action(_setup), do: :setup

    defp unexpected(other), do: "the state handler returned #{inspect(other)}"

    defp provider_states(states) when is_list(states) do
      Enum.map(states, &%{name: &1["name"], params: &1["params"] || %{}})
    end

    defp provider_states(_none), do: []

    defp provider(opts, description) do
      Map.get(opts.message_providers, description) || opts.fallback
    end

    # -- Responses --------------------------------------------------------------

    defp fail(conn, opts, what, reason) do
      text = if is_binary(reason), do: reason, else: inspect(reason)
      report(opts, "#{what}: #{text}")
      json(conn, 422, %{"error" => text})
    end

    defp report(%{report_to: {pid, ref}}, text),
      do: send(pid, {:pact_ex_callback_error, ref, text})

    defp report(_opts, _text), do: :ok

    defp json(conn, status, body) do
      conn
      |> Plug.Conn.put_resp_content_type("application/json", nil)
      |> Plug.Conn.send_resp(status, JSON.encode!(body))
    end

    # The result is `{contents, metadata}` or `contents`. Contents are a map or
    # list (JSON), `{binary, content_type}`, or a binary (text, or octet-stream
    # when it is not valid UTF-8).
    defp send_message(conn, {{body, type}, metadata})
         when is_binary(body) and is_binary(type) and is_map(metadata) do
      conn |> put_metadata(metadata) |> raw(body, type)
    end

    defp send_message(conn, {body, type}) when is_binary(body) and is_binary(type),
      do: raw(conn, body, type)

    defp send_message(conn, {contents, metadata}) when is_map(metadata),
      do: conn |> put_metadata(metadata) |> send_contents(contents)

    defp send_message(conn, contents), do: send_contents(conn, contents)

    defp send_contents(conn, contents) when is_binary(contents) do
      raw(
        conn,
        contents,
        if(String.valid?(contents), do: "text/plain", else: "application/octet-stream")
      )
    end

    defp send_contents(conn, contents), do: raw(conn, JSON.encode!(contents), "application/json")

    defp put_metadata(conn, metadata) do
      Plug.Conn.put_resp_header(
        conn,
        "pact-message-metadata",
        Base.encode64(JSON.encode!(metadata))
      )
    end

    defp raw(conn, body, type) do
      conn |> Plug.Conn.put_resp_content_type(type, nil) |> Plug.Conn.send_resp(200, body)
    end
  end
end
