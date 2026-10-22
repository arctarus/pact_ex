defmodule PactEx.MockServer do
  @moduledoc """
  A running Pact mock server.

  Start one with `PactEx.Consumer.start_mock_server/3`, or let
  `PactEx.Consumer.run/4` manage it. Send the requests of your test to `url`.
  """

  alias PactEx.{Error, Native}

  @enforce_keys [:port, :url, :pact_dir, :pact_ref]
  defstruct [:port, :url, :pact_dir, :pact_ref]

  @type t :: %__MODULE__{
          port: pos_integer(),
          url: String.t(),
          pact_dir: Path.t(),
          pact_ref: reference()
        }

  @doc false
  @spec build_url(String.t(), non_neg_integer()) :: String.t()
  def build_url(host, port) do
    host =
      if String.contains?(host, ":") and not String.starts_with?(host, "[") do
        "[" <> host <> "]"
      else
        host
      end

    "http://#{host}:#{port}"
  end

  @doc """
  Returns `true` if every expected request arrived and no unexpected request did.

  Returns `false` for a server that was already stopped.
  """
  @spec matched?(t()) :: boolean()
  def matched?(%__MODULE__{port: port}), do: Native.mock_server_matched(port)

  @doc """
  Returns the mismatches seen so far, as decoded maps.

  Returns `[]` when there are none, and for a server that was already stopped.
  See `PactEx.MismatchError` for the `"type"` values.
  """
  @spec mismatches(t()) :: [map()]
  def mismatches(%__MODULE__{port: port}) do
    case Native.mock_server_mismatches(port) do
      nil -> []
      json -> JSON.decode!(json)
    end
  end

  @doc """
  Writes the pact file to the server's `pact_dir`, creating the directory if needed.

  The file is named `<consumer>-<provider>.json`.

  ## Options

    * `:overwrite` - when `false` (the default), merges with an existing file.
      When `true`, replaces it.

  Returns `{:error, %PactEx.Error{}}` if the file cannot be written, or if the
  server was already stopped (code `3`). Raises `ArgumentError` on unknown
  options or a non-boolean `:overwrite`.
  """
  @spec write_pact(t(), keyword()) :: :ok | {:error, Error.t()}
  def write_pact(%__MODULE__{port: port, pact_dir: dir}, opts \\ []) do
    opts = Keyword.validate!(opts, overwrite: false)

    overwrite =
      case Keyword.fetch!(opts, :overwrite) do
        value when is_boolean(value) ->
          value

        other ->
          raise ArgumentError, "option :overwrite must be a boolean, got: #{inspect(other)}"
      end

    case Native.write_pact_file(port, dir, overwrite) do
      :ok -> :ok
      {:error, error} -> {:error, Error.from_native(error)}
    end
  end

  @doc """
  Stops the server and frees its resources. Always returns `:ok`, also when
  the server was already stopped.

  Read `matched?/1` and `mismatches/1` before calling it.
  """
  @spec stop(t()) :: :ok
  def stop(%__MODULE__{port: port}) do
    Native.cleanup_mock_server(port)
    :ok
  end
end
