defmodule PactEx.Verifier do
  @moduledoc """
  Verifies a provider against pacts, from files, directories or URLs.

      PactEx.Verifier.verify(
        provider: "animal_service",
        provider_url: "http://localhost:4000",
        dirs: ["pacts"],
        state_handler: fn
          "an alligator with the name Mary exists", _params, :setup -> MyApp.Animals.put("Mary")
          _state, _params, _action -> :ok
        end
      )

  The verifier replays each interaction against the provider and compares the
  responses. It runs in one native call, so `verify/1` blocks the calling
  process until it ends.

  ## Provider states

  `:state_handler` is a function of arity 3. It gets the state name, its params
  (a map, empty when the pact has none) and the action, `:setup` or `:teardown`
  (only with `state_change_teardown: true`). It returns:

    * `:ok`, to set the state up;
    * `{:ok, map}`, whose values the verifier can use in the request;
    * `{:error, reason}`, or it raises, to fail the interaction.

  An interaction without a state does not call the handler: the verifier sends
  the state `""` for it, and the endpoint answers it without your function.

  The verifier gives each state change `:request_timeout`, as it does each
  request to the provider. A handler that takes longer fails the interaction
  without a reason in `:callback_errors`, and it keeps running until
  `verify/1` returns.

  The handler does not run in the process that called `verify/1`. A small web
  server on `127.0.0.1` calls it, so anything bound to the calling process (its
  process dictionary, Mox expectations, an Ecto SQL sandbox checkout) needs a
  shared mode or an explicit allowance. A failing handler fails the verification
  at once, and its reason is in the `:callback_errors` of
  `PactEx.VerificationError`.

  The server needs the optional dependencies `:plug` and `:bandit`, which
  `verify/1` checks only when it needs the server. To call your own state change
  endpoint instead, give `:state_change_url`.

  ## Message providers

  `:message_providers` maps a message description to a function of arity 1. It
  gets the provider states of the message, a list of `%{name: String.t(),
  params: map()}`, and returns the message. That is `{contents, metadata}`, or
  just `contents`. Contents are a map or list (sent as JSON), a binary, or
  `{binary, content_type}`. `:fallback_message_provider` answers every
  description that has no function. A description with neither is a failed
  interaction that names it, as does a function that raises.

  The verifier asks the endpoint for each message at the host of
  `:provider_url`, so leave it at its default, `127.0.0.1`, when you verify
  messages. A pact can mix HTTP interactions and messages.

  ## Options

    * `:provider` - the provider name in the pacts. Required.
    * `:provider_url` - where the provider listens. Defaults to
      `"http://127.0.0.1"`.
    * `:files` - paths of pact files.
    * `:dirs` - directories of pact files. Only the files directly in each
      directory are read, and a file that is not a pact is an error.
    * `:urls` - URLs of pacts. A string, or a map with `:url` and either
      `:token` or `:username` and `:password`.
    * `:transports` - extra provider transports, such as
      `[%{protocol: "grpc", port: 50051}]`. Each map can also have `:path` and
      `:scheme`.
    * `:message_providers` and `:fallback_message_provider` - see above.
    * `:state_handler` or `:state_change_url` - see above. Giving both is an
      error. `:state_change_teardown` (default `false`) also calls it after each
      interaction.
    * `:filter_description`, `:filter_state` and `:filter_no_state` - verify
      only some interactions. `:consumers` (default `[]`) limits the consumers.
    * `:custom_headers` - a map of headers added to every request to the
      provider.
    * `:request_timeout` - milliseconds per request to the provider. Defaults to
      `5_000`.
    * `:disable_ssl_verification` - defaults to `false`.
    * `:broker` - verify the pacts of a Pact Broker: a keyword list with `:url`
      (required), `:token` or `:username` and `:password`, `:enable_pending`,
      `:include_wip_pacts_since`, `:consumer_version_selectors` (a list of maps,
      by default `mainBranch` and `deployedOrReleased`) and
      `:consumer_version_tags`. The broker also uses `:provider_tags` and
      `:provider_branch`. Here `:no_pacts_is_error` is checked by the verifier
      itself.
    * `:publish`, `:provider_version`, `:provider_branch`, `:provider_tags` and
      `:build_url` - publish the results. `publish: true` needs
      `:provider_version`. The verifier publishes only the results of pacts that
      came from a `:broker`. For `:files`, `:dirs` and `:urls` it publishes
      nothing. A failed publication is only logged, so `verify/1` still returns
      `:ok`.
    * `:no_pacts_is_error` - defaults to `true`: a verification that ran no
      interaction fails, whatever the source. A missing file or directory fails
      either way.

  ## Usage metrics

  Like the other Pact libraries, the native verifier ends each run by posting an
  anonymous usage metric to Google Analytics, and it waits for the answer with no
  timeout. On a network that drops packets, `verify/1` can block for a very long
  time. Set the environment variable `PACT_DO_NOT_TRACK=true` before the VM
  starts to turn it off.

  Raises `ArgumentError` on an unknown option or a combination that cannot work.
  """

  alias PactEx.{Error, Native, VerificationError}
  alias PactEx.Verifier.{EndpointServer, Options}

  # EndpointServer exists only with the optional :plug and :bandit, and it is
  # called only after a Code.ensure_loaded?/1 check.
  @compile {:no_warn_undefined, EndpointServer}

  @doc """
  Verifies the provider.

  Returns `:ok` when every interaction passed, and
  `{:error, %PactEx.VerificationError{}}` when one did not or when none ran
  (see `:no_pacts_is_error`). Raises `PactEx.Error` when the native verifier
  cannot start, for example on an argument with a NUL byte.
  """
  @spec verify(keyword()) :: :ok | {:error, VerificationError.t()}
  def verify(opts) do
    # Validate before anything starts, so a bad option leaves nothing running.
    opts = Options.validate!(opts)

    ref = make_ref()
    server = start_endpoint(opts, ref)

    result =
      try do
        Native.verify(Options.to_native(opts, server && server.port))
      after
        server && EndpointServer.stop(server)
      end

    conclude(result, opts, drain(ref))
  end

  @doc """
  Like `verify/1`, but returns `:ok` or raises the `PactEx.VerificationError`.
  """
  @spec verify!(keyword()) :: :ok
  def verify!(opts) do
    case verify(opts) do
      :ok -> :ok
      {:error, error} -> raise error
    end
  end

  defp start_endpoint(opts, ref) do
    if Options.needs_endpoint?(opts) do
      unless Code.ensure_loaded?(EndpointServer) do
        raise ArgumentError,
              "a :state_handler or :message_providers needs the optional dependencies " <>
                ":plug and :bandit. Add them to the deps of your project."
      end

      endpoint = opts |> Options.endpoint_opts() |> Map.put(:report_to, {self(), ref})

      case EndpointServer.start(endpoint) do
        {:ok, server} ->
          server

        {:error, reason} ->
          raise Error, "could not start the verifier endpoint: #{inspect(reason)}"
      end
    end
  end

  # The endpoint sent these before it answered the verifier, so they are
  # already in the mailbox when the verification returns.
  defp drain(ref, acc \\ []) do
    receive do
      {:pact_ex_callback_error, ^ref, text} -> drain(ref, [text | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp conclude({:error, error}, _opts, _callback_errors), do: raise(Error.from_native(error))

  defp conclude({:ok, %{exit_code: 0, json: json, output: output}}, opts, callback_errors) do
    report = JSON.decode!(json)

    # pact_verifier applies no_pacts_is_error only to a Pact Broker source. An
    # empty directory, or filters that match nothing, would pass.
    if opts[:no_pacts_is_error] and report["interactionResults"] == [] do
      {:error, error(0, report, output, callback_errors)}
    else
      :ok
    end
  end

  defp conclude({:ok, %{exit_code: code, json: json, output: output}}, _opts, callback_errors),
    do: {:error, error(code, JSON.decode!(json), output, callback_errors)}

  defp error(code, report, output, callback_errors) do
    %VerificationError{
      exit_code: code,
      report: report,
      output: output,
      callback_errors: callback_errors
    }
  end
end
