defmodule PactEx.Consumer do
  @moduledoc """
  Runs consumer-side contract tests against a Pact mock server.

      pact = PactEx.new("web", "users-api")

      interaction =
        PactEx.HTTP.interaction("get user")
        |> PactEx.HTTP.with_request(:get, "/users/1")
        |> PactEx.HTTP.will_respond_with(200, body: %{"id" => 1})

      PactEx.Consumer.run!(pact, [interaction], fn mock ->
        Req.get!(mock.url <> "/users/1")
      end)

  `run/4` starts a mock server, calls your function, checks that every
  expected request arrived and that no other did, then writes the pact file.
  Nothing is written when something did not match.

  ## How interactions are encoded

    * Paths, query values and header values are strings or matcher maps
      (see `PactEx.Matchers`). Query and header values may also be integers,
      floats or booleans, which become strings. A list gives a multi-valued
      parameter. `nil` and other types are rejected.
    * Query and header names are strings or atoms.
    * A map or list body is sent as JSON (`application/json` by default). A
      string body is sent as text (`text/plain` by default) when it is valid
      UTF-8 without NUL bytes, and as binary (`application/octet-stream` by
      default) otherwise. Set `:content_type` to override.

  The pact file is `<pact_dir>/<consumer>-<provider>.json`. It is merged with
  an existing file, so several runs can add interactions to the same pact.
  """

  alias PactEx.{Error, MismatchError, MockServer, Native, Pact}
  alias PactEx.Consumer.Apply
  alias PactEx.HTTP.Interaction

  @doc """
  Runs `fun` against a mock server for `interactions` and writes the pact if
  everything matched.

  `fun` receives the `t:PactEx.MockServer.t/0`. Its return value is ignored.
  The server is always stopped. If `fun` raises, throws or exits, nothing is
  written and the exception propagates.

  Takes the same options as `start_mock_server/3`.

  Returns:

    * `:ok` - everything matched and the pact was written.
    * `{:error, %PactEx.MismatchError{}}` - an expected request never arrived,
      or an unexpected one did. Nothing is written.
    * `{:error, %PactEx.Error{}}` - the server could not start, an interaction
      is invalid, or the pact file could not be written. `fun` does not run
      when the server cannot start.
  """
  @spec run(Pact.t(), [Interaction.t()], (MockServer.t() -> any()), keyword()) ::
          :ok | {:error, MismatchError.t() | Error.t()}
  def run(%Pact{} = pact, interactions, fun, opts \\ [])
      when is_list(interactions) and is_function(fun, 1) do
    case start_mock_server(pact, interactions, opts) do
      {:ok, mock} ->
        # The mock server owns the mismatches JSON and frees it on cleanup,
        # so `stop/1` must run after everything else.
        try do
          fun.(mock)
          finish(mock)
        after
          MockServer.stop(mock)
        end

      {:error, _error} = error ->
        error
    end
  end

  @doc """
  Like `run/4`, but returns `:ok` or raises the `PactEx.MismatchError` or
  `PactEx.Error`.
  """
  @spec run!(Pact.t(), [Interaction.t()], (MockServer.t() -> any()), keyword()) :: :ok
  def run!(%Pact{} = pact, interactions, fun, opts \\ []) do
    case run(pact, interactions, fun, opts) do
      :ok -> :ok
      {:error, error} -> raise error
    end
  end

  @doc """
  Starts a mock server for `interactions`.

  Use this when `run/4` is too rigid. You must call `PactEx.MockServer.stop/1`
  when done, and `PactEx.MockServer.write_pact/2` if you want the pact file.

  ## Options

    * `:host` - address to bind. Defaults to `"127.0.0.1"`.
    * `:port` - port to bind, from 0 to 65535. Defaults to `0`, which lets the
      OS pick a free port.

  Returns `{:error, %PactEx.Error{}}` if an interaction is invalid (for
  example, it has no request or a value of an unsupported type), if an argument contains a NUL byte, or if the
  server cannot bind. A missing response defaults to status 200.

  Raises `ArgumentError` on unknown options, a port out of range, or a NUL
  byte in the consumer, provider or an interaction description.
  """
  @spec start_mock_server(Pact.t(), [Interaction.t()], keyword()) ::
          {:ok, MockServer.t()} | {:error, Error.t()}
  def start_mock_server(%Pact{} = pact, interactions, opts \\ []) when is_list(interactions) do
    opts = Keyword.validate!(opts, host: "127.0.0.1", port: 0)
    host = Keyword.fetch!(opts, :host)
    port = Keyword.fetch!(opts, :port)

    with :ok <- validate_all(interactions) do
      pact_ref = Native.new_pact(pact.consumer, pact.provider)

      with :ok <- Apply.native(Native.with_specification(pact_ref, pact.spec)),
           :ok <- apply_all(pact_ref, interactions),
           {:ok, bound_port} <-
             Apply.native(Native.create_mock_server(pact_ref, host, port, "http", nil)) do
        {:ok,
         %MockServer{
           port: bound_port,
           url: MockServer.build_url(host, bound_port),
           pact_dir: pact.pact_dir,
           pact_ref: pact_ref
         }}
      end
    end
  end

  defp finish(mock) do
    if MockServer.matched?(mock) do
      MockServer.write_pact(mock, overwrite: false)
    else
      {:error, %MismatchError{mismatches: MockServer.mismatches(mock)}}
    end
  end

  defp validate_all(interactions), do: Apply.each_ok(interactions, &Apply.validate/1)

  defp apply_all(pact_ref, interactions) do
    Apply.each_ok(interactions, &Apply.interaction(pact_ref, &1))
  end
end
