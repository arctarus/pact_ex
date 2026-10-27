defmodule PactEx.Message do
  @moduledoc """
  An asynchronous message, such as an event on a queue.

      pact = PactEx.new("web", "weather-service")

      message =
        PactEx.Message.new("a weather data message")
        |> PactEx.Message.given("weather data for animals", %{"weather" => "cold"})
        |> PactEx.Message.with_contents(%{"temperature" => PactEx.Matchers.like(23.0)})
        |> PactEx.Message.with_metadata(%{"queue" => "weather.eu"})

      PactEx.Message.run!(pact, message, fn %PactEx.Message.Reified{contents: contents} ->
        WeatherConsumer.handle(contents)
      end)

  `run/4` builds the message, with matchers replaced by their example values,
  and passes it to your function. If the function returns, the message is
  written to the pact file. Messages need a pact with spec `:v4`, which is the
  default.

  The pact file is `<pact_dir>/<consumer>-<provider>.json`. It is merged with
  an existing file, so several runs can add messages to the same pact.

  ## Contents

  `with_contents/3` takes:

    * a map or list, sent as JSON (matchers are allowed, see `PactEx.Matchers`);
    * a binary: text when it is valid UTF-8 without NUL bytes, binary
      otherwise. Use the `:content_type` option to name its type;
    * a `t:PactEx.PluginContents.t/0` (see `PactEx.Plugin.contents/2`), which
      a plugin turns into the contents. The pact needs that plugin, see
      `PactEx.using_plugin/3`.

  Contents follow the body rules of `PactEx.Consumer`. A message needs
  contents: `nil` and `""` are rejected.

  Metadata values are sent as JSON, strings included, so the string `"5"`
  stays a string. A value can be a matcher map.
  """

  alias PactEx.{Error, Pact}
  alias PactEx.Message.{Reified, Runner}

  @enforce_keys [:description]
  defstruct description: nil,
            provider_states: [],
            contents: nil,
            content_type: nil,
            metadata: %{}

  @type t :: %__MODULE__{
          description: String.t(),
          provider_states: [{String.t(), map() | nil}],
          contents: term(),
          content_type: String.t() | nil,
          metadata: %{String.t() => term()}
        }

  @doc """
  Starts a message with `description`.
  """
  @spec new(String.t()) :: t()
  def new(description) when is_binary(description), do: %__MODULE__{description: description}

  @doc """
  Adds a provider state, with optional `params` (a map).

  States are kept in the order they are added.
  """
  @spec given(t(), String.t(), map() | nil) :: t()
  def given(%__MODULE__{} = message, state, params \\ nil)
      when is_binary(state) and (is_map(params) or is_nil(params)) do
    %{message | provider_states: message.provider_states ++ [{state, params}]}
  end

  @doc """
  Sets the contents of the message.

  `contents` is a map or list (JSON), a binary or a
  `t:PactEx.PluginContents.t/0`.

  ## Options

    * `:content_type` - the content type of the contents. For plugin contents
      it must name the same media type as the contents, or the run returns a
      `-101` error. Defaults to the type of the contents.

  Raises `ArgumentError` on unknown options.
  """
  @spec with_contents(t(), term(), keyword()) :: t()
  def with_contents(%__MODULE__{} = message, contents, opts \\ []) do
    opts = Keyword.validate!(opts, content_type: nil)
    %{message | contents: contents, content_type: Keyword.fetch!(opts, :content_type)}
  end

  @doc """
  Merges `metadata` into the metadata of the message.

  Keys are strings. A value is anything that encodes to JSON, or a matcher
  map.
  """
  @spec with_metadata(t(), map()) :: t()
  def with_metadata(%__MODULE__{} = message, metadata) when is_map(metadata) do
    %{message | metadata: Map.merge(message.metadata, metadata)}
  end

  @doc """
  Builds `message`, calls `fun` with it and writes the pact if `fun` returns.

  `fun` receives a `t:PactEx.Message.Reified.t/0`, which is the message as a
  provider would send it. Its return value is ignored. The plugins of the pact
  are loaded before `fun` runs and unloaded when it returns or raises. If `fun`
  raises, throws or exits, nothing is written and the exception propagates.

  `opts` takes no options yet, and raises `ArgumentError` on any. It keeps the
  signature in line with `PactEx.SyncMessage.run/4`.

  Returns `:ok`, or `{:error, %PactEx.Error{}}` when the message cannot be
  built. A `-101` error comes before any native call, and `fun` does not run.
  It is returned when:

    * the pact is not `:v4`: pact_ffi reifies a message of an older spec in a
      shape this library does not read;
    * the message has no contents (`nil` or `""`);
    * the contents are plugin contents and the pact has no plugin, or
      `:content_type` names another media type than they do;
    * the contents, a provider state param or a metadata value cannot be
      encoded as JSON, or an object repeats a key.
  """
  @spec run(Pact.t(), t(), (Reified.t() -> any()), keyword()) :: :ok | {:error, Error.t()}
  def run(%Pact{} = pact, %__MODULE__{} = message, fun, opts \\ []) when is_function(fun, 1) do
    Runner.run(pact, message, fun, Keyword.validate!(opts, []))
  end

  @doc """
  Like `run/4`, but returns `:ok` or raises the `PactEx.Error`.
  """
  @spec run!(Pact.t(), t(), (Reified.t() -> any()), keyword()) :: :ok
  def run!(%Pact{} = pact, %__MODULE__{} = message, fun, opts \\ []) do
    case run(pact, message, fun, opts) do
      :ok -> :ok
      {:error, error} -> raise error
    end
  end
end
