defmodule PactEx.SyncMessage do
  @moduledoc """
  A synchronous message: one request and one or more responses, such as a gRPC
  call.

      pact = PactEx.new("web", "user-service")

      message =
        PactEx.SyncMessage.new("get a user")
        |> PactEx.SyncMessage.given("user 1 exists")
        |> PactEx.SyncMessage.with_request(%{"id" => PactEx.Matchers.integer(1)})
        |> PactEx.SyncMessage.will_respond_with(%{"name" => PactEx.Matchers.like("Ann")})

      PactEx.SyncMessage.run!(pact, message, fn %PactEx.SyncMessage.Generated{} = generated ->
        UserConsumer.handle(generated.request, generated.responses)
      end)

  `run/4` builds the message, with matchers replaced by their example values,
  and passes it to your function. If the function returns, the message is
  written to the pact file. Synchronous messages need a pact with spec `:v4`,
  which is the default.

  The pact file is `<pact_dir>/<consumer>-<provider>.json`. It is merged with
  an existing file, so several runs can add messages to the same pact.

  ## Contents

  `with_request/3` and `will_respond_with/3` take a map or list (sent as JSON,
  matchers are allowed, see `PactEx.Matchers`) or a binary (text when it is
  valid UTF-8 without NUL bytes, binary otherwise). They follow the body rules
  of `PactEx.Consumer`. A message needs a request, and every response needs
  contents: `nil` and `""` are rejected.

  `with_plugin_contents/2` sets the request and the responses at once through
  a plugin, as pact-go's `WithContents` does. See `PactEx.Plugin.contents/2`.
  The pact needs that plugin, see `PactEx.using_plugin/3`.
  """

  alias PactEx.{Error, Pact, PluginContents}
  alias PactEx.SyncMessage.{Generated, Runner}

  @enforce_keys [:description]
  defstruct description: nil,
            provider_states: [],
            request: nil,
            request_content_type: nil,
            responses: [],
            plugin_contents: nil

  @type t :: %__MODULE__{
          description: String.t(),
          provider_states: [{String.t(), map() | nil}],
          request: term(),
          request_content_type: String.t() | nil,
          responses: [{term(), String.t() | nil}],
          plugin_contents: PluginContents.t() | nil
        }

  @doc """
  Starts a synchronous message with `description`.
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
  Sets the request of the message.

  `contents` is a map or list (JSON) or a binary.

  ## Options

    * `:content_type` - the content type of the request. Defaults to the type
      of the contents.

  Raises `ArgumentError` on unknown options.
  """
  @spec with_request(t(), term(), keyword()) :: t()
  def with_request(%__MODULE__{} = message, contents, opts \\ []) do
    opts = Keyword.validate!(opts, content_type: nil)
    %{message | request: contents, request_content_type: Keyword.fetch!(opts, :content_type)}
  end

  @doc """
  Adds a response to the message.

  `contents` is a map or list (JSON) or a binary. Responses are kept in the
  order they are added, each with its own content type.

  ## Options

    * `:content_type` - the content type of this response. Defaults to the
      type of the contents.

  Raises `ArgumentError` on unknown options.
  """
  @spec will_respond_with(t(), term(), keyword()) :: t()
  def will_respond_with(%__MODULE__{} = message, contents, opts \\ []) do
    opts = Keyword.validate!(opts, content_type: nil)
    response = {contents, Keyword.fetch!(opts, :content_type)}
    %{message | responses: message.responses ++ [response]}
  end

  @doc """
  Sets the whole request and response of the message through a plugin.

  The plugin builds them from `contents`, so the request and responses given
  with `with_request/3` and `will_respond_with/3` are not used. When the
  request or a response also names a content type, it must be the media type
  of `contents`, or the run returns a `-101` error.
  """
  @spec with_plugin_contents(t(), PluginContents.t()) :: t()
  def with_plugin_contents(%__MODULE__{} = message, %PluginContents{} = contents) do
    %{message | plugin_contents: contents}
  end

  @doc """
  Builds `message`, calls `fun` with it and writes the pact if `fun` returns.

  `fun` receives a `t:PactEx.SyncMessage.Generated.t/0`. Its return value is
  ignored. The plugins of the pact are loaded before `fun` runs and unloaded
  when it returns or raises. If `fun` raises, throws or exits, nothing is
  written and the exception propagates.

  ## Options

    * `:transport` - not supported yet, and anything but `nil` raises
      `ArgumentError`. Defaults to `nil`.
    * `:host` - the host of the transport. Defaults to `"127.0.0.1"`.
    * `:port` - the port of the transport, `0` to let the system choose one.
      Defaults to `0`.
    * `:transport_config` - the configuration of the transport, a map.
      Defaults to `nil`.

  Raises `ArgumentError` on unknown options.

  Returns `:ok`, or `{:error, %PactEx.Error{}}` when the message cannot be
  built. A `-101` error comes before any native call, and `fun` does not run.
  It is returned when:

    * the pact is not `:v4`;
    * there are no plugin contents and the request is `nil` or `""`, or a
      response is. A `nil` response would be dropped without a word, and `fun`
      would get one response fewer;
    * the plugin contents are set and the pact has no plugin, or a content type
      of the message names another media type than they do;
    * the request, a response, a provider state param or the plugin contents
      cannot be encoded as JSON, or an object repeats a key.
  """
  @spec run(Pact.t(), t(), (Generated.t() -> any()), keyword()) :: :ok | {:error, Error.t()}
  def run(%Pact{} = pact, %__MODULE__{} = message, fun, opts \\ []) when is_function(fun, 1) do
    opts =
      Keyword.validate!(opts, transport: nil, host: "127.0.0.1", port: 0, transport_config: nil)

    Runner.run(pact, message, fun, opts)
  end

  @doc """
  Like `run/4`, but returns `:ok` or raises the `PactEx.Error`.
  """
  @spec run!(Pact.t(), t(), (Generated.t() -> any()), keyword()) :: :ok
  def run!(%Pact{} = pact, %__MODULE__{} = message, fun, opts \\ []) do
    case run(pact, message, fun, opts) do
      :ok -> :ok
      {:error, error} -> raise error
    end
  end
end
