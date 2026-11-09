defmodule PactEx.Verifier.Options do
  @moduledoc false

  # Validates the options of `PactEx.Verifier.verify/1` and turns them into the
  # config map that `PactEx.Native.verify/1` takes.

  @defaults [
    provider: nil,
    provider_url: "http://127.0.0.1",
    transports: [],
    files: [],
    dirs: [],
    urls: [],
    broker: nil,
    state_handler: nil,
    state_change_url: nil,
    state_change_teardown: false,
    message_providers: %{},
    fallback_message_provider: nil,
    filter_description: nil,
    filter_state: nil,
    filter_no_state: false,
    consumers: [],
    custom_headers: %{},
    request_timeout: 5_000,
    disable_ssl_verification: false,
    publish: false,
    provider_version: nil,
    provider_branch: nil,
    provider_tags: [],
    build_url: nil,
    no_pacts_is_error: true
  ]

  @broker_defaults [
    url: nil,
    token: nil,
    username: nil,
    password: nil,
    enable_pending: false,
    include_wip_pacts_since: nil,
    consumer_version_selectors: [%{"mainBranch" => true}, %{"deployedOrReleased" => true}],
    consumer_version_tags: []
  ]

  @doc """
  Validates `opts` and returns them with the defaults filled in. Raises
  `ArgumentError` on an unknown option, a missing `:provider`, or a combination
  that cannot work.
  """
  @spec validate!(keyword()) :: keyword()
  def validate!(opts) do
    opts = Keyword.validate!(opts, @defaults)

    unless is_binary(opts[:provider]) and opts[:provider] != "" do
      raise ArgumentError, "option :provider is required and must be a non-empty string"
    end

    if opts[:state_handler] != nil and opts[:state_change_url] != nil do
      raise ArgumentError, "give :state_handler or :state_change_url, not both"
    end

    check_fun!(opts, :state_handler, 3)
    check_fun!(opts, :fallback_message_provider, 1)
    check_message_providers!(opts[:message_providers])
    opts = Keyword.update!(opts, :broker, &broker!/1)

    if opts[:publish] == true and opts[:provider_version] in [nil, ""] do
      raise ArgumentError, "publish: true requires :provider_version"
    end

    opts
  end

  defp broker!(nil), do: nil

  defp broker!(broker) when is_list(broker) do
    broker = Keyword.validate!(broker, @broker_defaults)

    unless is_binary(broker[:url]) and broker[:url] != "" do
      raise ArgumentError, "option :broker needs a :url"
    end

    unless Enum.all?(broker[:consumer_version_selectors], &is_map/1) do
      raise ArgumentError, "the :consumer_version_selectors of :broker must be maps"
    end

    broker
  end

  defp broker!(other) do
    raise ArgumentError, "option :broker must be a keyword list, got: #{inspect(other)}"
  end

  defp check_fun!(opts, key, arity) do
    case opts[key] do
      nil ->
        :ok

      fun when is_function(fun, arity) ->
        :ok

      other ->
        raise ArgumentError,
              "option #{inspect(key)} must be a function of arity #{arity}, got: #{inspect(other)}"
    end
  end

  defp check_message_providers!(providers) when is_map(providers) do
    for {description, fun} <- providers do
      unless is_binary(description) and is_function(fun, 1) do
        raise ArgumentError,
              ":message_providers must map a description (a string) to a function of arity 1, " <>
                "got: #{inspect({description, fun})}"
      end
    end

    :ok
  end

  defp check_message_providers!(other) do
    raise ArgumentError, "option :message_providers must be a map, got: #{inspect(other)}"
  end

  @doc """
  Whether a verification needs the internal endpoint: a state handler, or
  message providers.
  """
  @spec needs_endpoint?(keyword()) :: boolean()
  def needs_endpoint?(opts) do
    opts[:state_handler] != nil or opts[:message_providers] != %{} or
      opts[:fallback_message_provider] != nil
  end

  @doc """
  The endpoint options for a validated `opts`: the callbacks, without the
  process to report to.
  """
  @spec endpoint_opts(keyword()) :: map()
  def endpoint_opts(opts) do
    %{
      state_handler: opts[:state_handler],
      message_providers: opts[:message_providers],
      fallback: opts[:fallback_message_provider]
    }
  end

  @doc """
  The config map for `PactEx.Native.verify/1`. `endpoint_port` is the port of the
  internal endpoint, or `nil` when there is none.
  """
  @spec to_native(keyword(), pos_integer() | nil) :: map()
  def to_native(opts, endpoint_port) do
    opts = validate!(opts)
    uri = URI.parse(opts[:provider_url])

    %{
      app_version: app_version(),
      provider_name: opts[:provider],
      provider_scheme: uri.scheme || "http",
      provider_host: uri.host || "127.0.0.1",
      provider_port: uri.port || 0,
      provider_path: uri.path || "/",
      transports:
        Enum.map(opts[:transports], &transport/1) ++ message_transport(opts, endpoint_port),
      filter_description: opts[:filter_description],
      filter_state: opts[:filter_state],
      filter_no_state: opts[:filter_no_state],
      state_change_url: state_change_url(opts, endpoint_port),
      state_change_teardown: opts[:state_change_teardown],
      disable_ssl_verification: opts[:disable_ssl_verification],
      request_timeout_ms: opts[:request_timeout],
      publish: publish(opts),
      consumer_filters: opts[:consumers],
      custom_headers: Enum.map(opts[:custom_headers], &header/1),
      files: opts[:files],
      dirs: opts[:dirs],
      urls: Enum.map(opts[:urls], &url_source/1),
      broker: broker(opts),
      no_pacts_is_error: opts[:no_pacts_is_error]
    }
  end

  defp app_version, do: to_string(Application.spec(:pact_ex, :vsn) || "unknown")

  defp transport(transport) do
    %{
      protocol: Map.fetch!(transport, :protocol),
      port: Map.fetch!(transport, :port),
      path: Map.get(transport, :path),
      scheme: Map.get(transport, :scheme)
    }
  end

  # The verifier sends a message request to the "message" transport, over HTTP,
  # at the host of the provider URL. That host is 127.0.0.1 unless you set
  # `:provider_url`.
  defp message_transport(opts, port) do
    if opts[:message_providers] != %{} or opts[:fallback_message_provider] != nil do
      [%{protocol: "message", port: port, path: "/_pact/messages", scheme: "http"}]
    else
      []
    end
  end

  defp state_change_url(opts, port) do
    if opts[:state_handler] do
      "http://127.0.0.1:#{port}/_pact/state"
    else
      opts[:state_change_url]
    end
  end

  # The provider tags and the branch are the ones of the verification, which
  # the broker uses to pick the pacts too.
  defp broker(opts) do
    if broker = opts[:broker] do
      %{
        url: broker[:url],
        username: broker[:username],
        password: broker[:password],
        token: broker[:token],
        enable_pending: broker[:enable_pending],
        include_wip_pacts_since: broker[:include_wip_pacts_since],
        provider_tags: opts[:provider_tags],
        provider_branch: opts[:provider_branch],
        consumer_version_selectors:
          Enum.map(broker[:consumer_version_selectors], &JSON.encode!/1),
        consumer_version_tags: broker[:consumer_version_tags]
      }
    end
  end

  defp publish(opts) do
    if opts[:publish] do
      %{
        provider_version: opts[:provider_version],
        build_url: opts[:build_url],
        provider_tags: opts[:provider_tags],
        provider_branch: opts[:provider_branch]
      }
    end
  end

  defp header({name, value}), do: %{name: to_string(name), value: to_string(value)}

  # A URL source is a string, or a map with `:url` and the credentials.
  defp url_source(url) when is_binary(url),
    do: %{url: url, username: nil, password: nil, token: nil}

  defp url_source(%{url: url} = source) do
    %{
      url: url,
      username: Map.get(source, :username),
      password: Map.get(source, :password),
      token: Map.get(source, :token)
    }
  end
end
