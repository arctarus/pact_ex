defmodule PactEx.Log do
  @moduledoc """
  Configures where the native Pact library writes its logs.

  The native library keeps one logger for the whole OS process. It can be set
  up once, and it cannot be changed or removed afterwards. Call `init/1` once,
  early (for example in `test/test_helper.exs`), before the first mock server
  starts.

      PactEx.Log.init(level: :debug, sink: {:file, "tmp/pact.log"})

  A `:stdout` or `:stderr` sink mixes Pact's output with your test output.
  Prefer a file when you only need the logs to debug a failing contract.

  Logs are never forwarded to Elixir's `Logger`.
  """

  alias PactEx.{Error, Native}

  @levels [:off, :error, :warn, :info, :debug, :trace]

  @type level :: :off | :error | :warn | :info | :debug | :trace
  @type sink :: :stdout | :stderr | {:file, Path.t()}

  @doc """
  Sets up the native logger.

  Succeeds only once per OS process. After a logger is applied, a call whose
  sink can be set up returns `{:error, :already_initialized}`, whatever its
  options. A sink that fails to set up still returns its own error. Invalid
  options still raise.

  ## Options

    * `:level` - the most verbose level to write: `:off`, `:error`, `:warn`,
      `:info`, `:debug` or `:trace`. Defaults to `:info`.
    * `:sink` - where to write: `:stdout`, `:stderr` or `{:file, path}`.
      Defaults to `:stdout`. A file sink appends to the file, creates it and
      any missing parent directories, and is opened even when the logger turns
      out to be initialised already. The path must not be blank or start or
      end with whitespace, because the native library would trim it.

  Returns:

    * `:ok` - the logger is set up.
    * `{:error, :already_initialized}` - a logger is already set up in this
      OS process.
    * `{:error, %PactEx.Error{}}` - the sink could not be set up. Code `-6`
      means the log file could not be opened. Code `-100` means the path
      contains a NUL byte. No logger is applied by the failed call, so you can
      call `init/1` again with a different sink, as long as no logger was
      applied earlier.

  Raises `ArgumentError` for an unknown option, an unknown level, or a sink
  that is not `:stdout`, `:stderr` or `{:file, path}` with a UTF-8 path that is
  not blank and has no leading or trailing whitespace.
  """
  @spec init(keyword()) :: :ok | {:error, :already_initialized} | {:error, Error.t()}
  def init(opts \\ []) do
    opts = Keyword.validate!(opts, level: :info, sink: :stdout)
    level = validate_level!(Keyword.fetch!(opts, :level))
    sink = encode_sink!(Keyword.fetch!(opts, :sink))

    case Native.init_logger(sink, level) do
      :ok -> :ok
      {:error, %{function: "pactffi_logger_apply", code: -1}} -> {:error, :already_initialized}
      {:error, error} -> {:error, Error.from_native(error)}
    end
  end

  defp validate_level!(level) when level in @levels, do: level

  defp validate_level!(other) do
    raise ArgumentError,
          "option :level must be one of #{inspect(@levels)}, got: #{inspect(other)}"
  end

  defp encode_sink!(:stdout), do: "stdout"
  defp encode_sink!(:stderr), do: "stderr"

  defp encode_sink!({:file, path} = sink) when is_binary(path) do
    # The native library trims the sink specifier, so it would silently open a
    # different path, or reject a blank one with a misleading "unknown sink".
    if String.valid?(path) and String.trim(path) == path and path != "" do
      "file " <> path
    else
      bad_sink!(sink)
    end
  end

  defp encode_sink!(other), do: bad_sink!(other)

  defp bad_sink!(other) do
    raise ArgumentError,
          "option :sink must be :stdout, :stderr or {:file, path} with a UTF-8 path " <>
            "that is not blank and has no leading or trailing whitespace, got: #{inspect(other)}"
  end
end
