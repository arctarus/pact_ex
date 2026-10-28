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
      parameter. `nil`, an empty list and other types are rejected: an empty
      list would drop the parameter without a word.
    * Query and header names are strings or atoms. An atom header name is
      written as Req writes it: underscores become dashes and ASCII letters
      lower case (`:x_request_id` is `"x-request-id"`). Query names and
      string names are not changed.
    * Each request and response has one body content type. The candidates are
      the `:content_type` option, the `Content-Type` header, and the default
      of the body type. Each is trimmed and the first one that pact_ffi can
      parse is used, so a type such as `"application/json; charset"` is
      skipped. That one string is passed with the body, and when it came from
      a string header the header is written with it. The header name can be in
      any case and is written as `Content-Type`. Its value can be a string, a
      matcher (its `"value"` is used) or a list (its first element is used).
      Two headers that differ only in case are an error. A header that was not
      the source of the type is sent as you wrote it. A `Content-Type` value
      that pact_ffi would turn into an empty list (a map or JSON string with
      `"value" => []`, a matcher too) returns
      `{:error, %PactEx.Error{code: -101}}`, with or without a body. That
      holds for any element of a list. As the whole header or the last
      element, pact_ffi aborts the VM on it. Before a later element, it
      records an empty string. An empty or whitespace-only string (as the
      value, an element or a matcher's `"value"`) is rejected too. On a
      request no request of the interaction can match such a header, and on
      a response no provider can produce it.
    * The default is `application/json` for a map or list, `text/plain` for a
      string that is valid UTF-8 without NUL bytes, and
      `application/octet-stream` for any other binary.
    * A map or list body is sent as JSON. With an XML content type
      (`application/xml`, `text/xml`, or `application/` or `text/` with a
      `+xml` suffix) or `application/x-www-form-urlencoded`, pact_ffi reads
      JSON as a description of the body in its own format. That also applies to
      a string body that pact_ffi's sniffing takes for JSON. The sniffing reads
      only the first characters, after optional whitespace: `true`, `false`,
      `null`, an ASCII digit, a quote, `[`, or `{` followed by optional
      whitespace and then `}` or a quote and a word character. The rest of the
      text is not looked at (`1=a&2=b` counts). pact_ffi panics on some
      descriptions, which aborts the VM, so PactEx checks them first and
      returns `{:error, %PactEx.Error{code: -101}}` naming the interaction and
      the path of the problem. An XML description is `%{"root" => element}`,
      where an element is
      `%{"name" => ..., "attributes" => ..., "children" => [...]}`, a text node
      is `%{"content" => ...}`, and a matcher element is
      `%{"pact:matcher:type" => ..., "value" => element}`. A form description
      is a map of strings, numbers, matchers with such a value and lists of
      them (nested maps, booleans, `nil` and keys that start with `"pact:"` are
      errors, because pact_ffi would drop them). A type that is both JSON and
      XML (`application/xml+json`) is JSON.
    * Every JSON PactEx writes is decoded again and an object that repeats a
      key is an error at any depth, for every content type. That covers
      `%{a: 1, "a" => 2}`, structs that encode to a repeated key, and matcher
      maps in headers and provider state params.
    * A string body is sent byte for byte, except under an XML or form type
      when pact_ffi's sniffing takes it for JSON. Then it must be a valid JSON
      description (for example `1=a&2=b` under a form type is an error). Any
      other body type is an error.

  The pact file is `<pact_dir>/<consumer>-<provider>.json`. It is merged with
  an existing file, so several runs can add interactions to the same pact.
  """

  alias PactEx.Consumer.Apply
  alias PactEx.{Error, MismatchError, MockServer, Native, Pact, Plugin}
  alias PactEx.HTTP.Interaction

  @entry_point "PactEx.Consumer.start_mock_server/3"

  @doc """
  Runs `fun` against a mock server for `interactions` and writes the pact if
  everything matched.

  `fun` receives the `t:PactEx.MockServer.t/0`. Its return value is ignored.
  The server is stopped when `fun` returns, raises, throws or exits. If `fun`
  raises, throws or exits, nothing is written and the exception propagates. A
  brutal kill of the calling process (an ExUnit timeout or a linked crash)
  skips the cleanup, and the server lives until the OS process exits.

  Takes the same options as `start_mock_server/3`.

  Returns:

    * `:ok` - everything matched and the pact was written.
    * `{:error, %PactEx.MismatchError{}}` - an expected request never arrived,
      or an unexpected one did. Nothing is written.
    * `{:error, %PactEx.Error{}}` - the server could not start, an interaction
      is invalid, or the pact file could not be written. `fun` does not run
      when the server cannot start. It is also returned, with code `-102`,
      when the server reports a failed match without any mismatch details, for
      example a plugin mock server that failed to answer or a server that `fun`
      already stopped. Nothing is written.
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

  The plugins of the pact (see `PactEx.using_plugin/3`) are loaded first, in
  order. They stay loaded until `PactEx.MockServer.stop/1`. When this function
  returns an error or raises, they are already unloaded. An interaction with
  plugin contents (`PactEx.Plugin.contents/2`) needs at least one plugin in the
  pact and a pact with spec `:v4`, or this function returns a `-101` error
  before any native call. A plugin that is not on disk is installed by the
  plugin driver, which needs network access.

  ## Options

    * `:host` - address to bind. Defaults to `"127.0.0.1"`.
    * `:port` - port to bind, from 0 to 65535. Defaults to `0`, which lets the
      OS pick a free port.

  Returns `{:error, %PactEx.Error{}}` if an interaction is invalid (for
  example, it has no request or a value of an unsupported type), if an argument
  contains a NUL byte, if a plugin cannot be loaded, or if the server cannot
  bind. A missing response defaults to status 200.

  Raises `ArgumentError` on unknown options, a port out of range, or a NUL
  byte in the consumer, provider or an interaction description.
  """
  @spec start_mock_server(Pact.t(), [Interaction.t()], keyword()) ::
          {:ok, MockServer.t()} | {:error, Error.t()}
  def start_mock_server(%Pact{} = pact, interactions, opts \\ []) when is_list(interactions) do
    opts = Keyword.validate!(opts, host: "127.0.0.1", port: 0)
    host = Keyword.fetch!(opts, :host)
    port = Keyword.fetch!(opts, :port)

    plugin_contents? = Enum.any?(interactions, &Apply.plugin_contents?/1)

    with :ok <- validate_all(interactions),
         :ok <- Apply.check_plugins_declared(plugin_contents?, pact.plugins, @entry_point),
         :ok <- Apply.check_plugins_unique(pact.plugins, @entry_point),
         :ok <- Apply.check_plugin_spec(plugin_contents?, pact.spec, @entry_point) do
      pact_ref = Native.new_pact(pact.consumer, pact.provider)

      # Once the pact exists, every way out except `{:ok, mock}` unloads the
      # plugins. `MockServer.stop/1` does it for the `{:ok, mock}` case.
      try do
        build(pact, pact_ref, interactions, host, port)
      catch
        kind, reason ->
          stacktrace = __STACKTRACE__
          Plugin.cleanup(pact_ref)
          :erlang.raise(kind, reason, stacktrace)
      else
        {:ok, _mock} = ok ->
          ok

        {:error, %Error{}} = error ->
          Plugin.cleanup(pact_ref)
          error
      end
    end
  end

  defp build(pact, pact_ref, interactions, host, port) do
    with :ok <- Plugin.load_all(pact_ref, pact),
         :ok <- Apply.native(Native.with_specification(pact_ref, pact.spec)),
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

  defp finish(mock) do
    matched? = MockServer.matched?(mock)
    mismatches = if matched?, do: [], else: MockServer.mismatches(mock)

    case verdict(matched?, mismatches) do
      :match -> MockServer.write_pact(mock, overwrite: false)
      {:error, _error} = error -> error
    end
  end

  # A failed match with no mismatches is not a contract mismatch. A plugin
  # mock server that fails to answer looks like this, and so does a server
  # that `fun` already stopped (an unknown port is never "matched").
  @doc false
  @spec verdict(boolean(), [map()]) :: :match | {:error, MismatchError.t() | Error.t()}
  def verdict(true, _mismatches), do: :match

  def verdict(false, []) do
    {:error,
     %Error{
       function: "PactEx.Consumer.run/4",
       code: -102,
       message:
         "the mock server reported a failed match without mismatch details, for example " <>
           "a plugin mock server that failed to answer or a server that was already " <>
           "stopped. Nothing was written."
     }}
  end

  def verdict(false, mismatches), do: {:error, %MismatchError{mismatches: mismatches}}

  defp validate_all(interactions), do: Apply.each_ok(interactions, &Apply.validate/1)

  defp apply_all(pact_ref, interactions) do
    Apply.each_ok(interactions, &Apply.interaction(pact_ref, &1))
  end
end
