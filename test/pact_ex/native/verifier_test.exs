defmodule PactEx.Native.VerifierTest do
  use ExUnit.Case, async: false

  alias PactEx.{Consumer, HTTP, Native}

  @moduletag :tmp_dir

  defp base_config(overrides) do
    Map.merge(
      %{
        app_version: "0.0.0",
        provider_name: "verifier-provider",
        provider_scheme: "http",
        provider_host: "127.0.0.1",
        provider_port: 0,
        provider_path: "/",
        transports: [],
        filter_description: nil,
        filter_state: nil,
        filter_no_state: false,
        state_change_url: nil,
        state_change_teardown: false,
        disable_ssl_verification: false,
        request_timeout_ms: 5_000,
        publish: nil,
        consumer_filters: [],
        custom_headers: [],
        files: [],
        dirs: [],
        urls: [],
        broker: nil,
        no_pacts_is_error: true
      },
      overrides
    )
  end

  test "verifies a file pact against a running provider", %{tmp_dir: dir} do
    pact = PactEx.new("verifier-consumer", "verifier-provider", pact_dir: dir)

    i =
      HTTP.interaction("ping")
      |> HTTP.with_request(:get, "/ping")
      |> HTTP.will_respond_with(200, body: "pong", content_type: "text/plain")

    :ok = Consumer.run(pact, [i], fn m -> Req.get!(m.url <> "/ping") end)

    # Reuse a plan 1 mock server as a stand-in provider that answers /ping.
    {:ok, provider} = Consumer.start_mock_server(PactEx.new("x", "y"), [i])

    try do
      file = Path.join(dir, "verifier-consumer-verifier-provider.json")

      assert {:ok, %{exit_code: 0, json: json}} =
               Native.verify(base_config(%{provider_port: provider.port, files: [file]}))

      assert JSON.decode!(json)["result"] == true
    after
      PactEx.MockServer.stop(provider)
    end
  end

  # pact_verifier applies no_pacts_is_error only to a Pact Broker source. Task 3
  # adds the check for files and directories in Elixir.
  test "directory sources ignore no_pacts_is_error", %{tmp_dir: dir} do
    empty = Path.join(dir, "empty")
    File.mkdir_p!(empty)
    assert {:ok, %{exit_code: 0, json: json}} = Native.verify(base_config(%{dirs: [empty]}))
    assert JSON.decode!(json)["interactionResults"] == []

    assert {:ok, %{exit_code: code}} =
             Native.verify(base_config(%{dirs: [Path.join(dir, "missing")]}))

    assert code != 0
  end

  test "a port outside 0..65535 raises ArgumentError" do
    assert_raise ArgumentError, fn -> Native.verify(base_config(%{provider_port: 70_000})) end

    assert_raise ArgumentError, fn ->
      Native.verify(
        base_config(%{transports: [%{protocol: "grpc", port: -1, path: nil, scheme: nil}]})
      )
    end
  end

  test "a NUL byte in a string is an error, not a crash" do
    assert {:error, %{code: -100}} = Native.verify(base_config(%{provider_name: "a\0b"}))
  end

  test "a consumer version selector that is not JSON names the problem" do
    broker = %{
      url: "http://127.0.0.1:1",
      username: nil,
      password: nil,
      token: nil,
      enable_pending: false,
      include_wip_pacts_since: nil,
      provider_tags: [],
      provider_branch: nil,
      consumer_version_selectors: ["not json"],
      consumer_version_tags: []
    }

    assert {:error, %{function: "pactffi_verifier_broker_source_with_selectors", message: msg}} =
             Native.verify(base_config(%{broker: broker}))

    assert msg =~ "not valid JSON"
  end
end
