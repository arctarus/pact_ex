defmodule PactEx.VerifierTest do
  use ExUnit.Case, async: true

  alias PactEx.Test.AnimalInteractions
  alias PactEx.Verifier
  alias PactEx.Verifier.Options

  describe "Options.to_native/2" do
    test "maps the options onto the native config" do
      config =
        Options.to_native(
          [
            provider: "p",
            provider_url: "https://api.local:8443/base",
            files: ["a.json"],
            consumers: ["c"]
          ],
          nil
        )

      assert %{
               provider_name: "p",
               provider_scheme: "https",
               provider_host: "api.local",
               provider_port: 8443,
               provider_path: "/base",
               files: ["a.json"],
               consumer_filters: ["c"],
               state_change_url: nil,
               broker: nil,
               request_timeout_ms: 5_000,
               no_pacts_is_error: true
             } = config
    end

    test "the default provider URL is 127.0.0.1, where the endpoint binds" do
      assert %{provider_host: "127.0.0.1", provider_scheme: "http"} =
               Options.to_native([provider: "p"], nil)
    end

    test "a state handler becomes the state change URL of the endpoint" do
      config = Options.to_native([provider: "p", state_handler: fn _, _, _ -> :ok end], 4321)
      assert config.state_change_url == "http://127.0.0.1:4321/_pact/state"
    end

    test "transports, headers and URL sources get their native shape" do
      config =
        Options.to_native(
          [
            provider: "p",
            transports: [%{protocol: "grpc", port: 50_051}],
            custom_headers: %{"x-id" => "1"},
            urls: ["http://x/pact.json", %{url: "http://y", token: "t"}]
          ],
          nil
        )

      assert config.transports == [%{protocol: "grpc", port: 50_051, path: nil, scheme: nil}]
      assert config.custom_headers == [%{name: "x-id", value: "1"}]

      assert config.urls == [
               %{url: "http://x/pact.json", username: nil, password: nil, token: nil},
               %{url: "http://y", username: nil, password: nil, token: "t"}
             ]
    end

    test "message providers add the message transport of the endpoint" do
      transport = %{protocol: "message", port: 4321, path: "/_pact/messages", scheme: "http"}
      fun = fn _ -> %{} end

      for opts <- [[message_providers: %{"d" => fun}], [fallback_message_provider: fun]] do
        assert %{transports: [^transport]} = Options.to_native([provider: "p"] ++ opts, 4321)
      end

      assert %{transports: [%{protocol: "grpc"}, ^transport]} =
               Options.to_native(
                 [
                   provider: "p",
                   transports: [%{protocol: "grpc", port: 1}],
                   message_providers: %{"d" => fun}
                 ],
                 4321
               )

      assert %{transports: []} = Options.to_native([provider: "p", message_providers: %{}], nil)
    end

    test "a broker becomes the native broker source, with the tags of the verification" do
      config =
        Options.to_native(
          [
            provider: "p",
            broker: [
              url: "http://broker",
              token: "t",
              consumer_version_selectors: [%{"latest" => true}]
            ],
            provider_tags: ["prod"],
            provider_branch: "main"
          ],
          nil
        )

      assert %{
               url: "http://broker",
               token: "t",
               username: nil,
               enable_pending: false,
               provider_tags: ["prod"],
               provider_branch: "main",
               consumer_version_selectors: [~s({"latest":true})],
               consumer_version_tags: []
             } = config.broker

      default = Options.to_native([provider: "p", broker: [url: "http://broker"]], nil)

      assert default.broker.consumer_version_selectors ==
               [~s({"mainBranch":true}), ~s({"deployedOrReleased":true})]
    end

    test "an invalid broker raises ArgumentError" do
      for {broker, message} <- [
            {[], ~r/needs a :url/},
            {[url: "http://b", tokn: "t"], ~r/unknown keys \[:tokn\]/},
            {[url: "http://b", consumer_version_selectors: ["latest"]], ~r/must be maps/},
            {"http://b", ~r/must be a keyword list/}
          ] do
        assert_raise ArgumentError, message, fn ->
          Options.to_native([provider: "p", broker: broker], nil)
        end
      end
    end

    test "publishing needs the provider version" do
      assert %{publish: %{provider_version: "1.0.0", provider_tags: []}} =
               Options.to_native([provider: "p", publish: true, provider_version: "1.0.0"], nil)

      assert %{publish: nil} = Options.to_native([provider: "p"], nil)
    end

    test "invalid options raise ArgumentError" do
      handler = fn _, _, _ -> :ok end

      for {opts, message} <- [
            {[], ~r/:provider is required/},
            {[provider: "p", foo: 1], ~r/unknown keys \[:foo\]/},
            {[provider: "p", state_handler: handler, state_change_url: "http://x"], ~r/not both/},
            {[provider: "p", state_handler: fn -> :ok end], ~r/function of arity 3/},
            {[provider: "p", message_providers: %{"d" => fn -> :ok end}], ~r/arity 1/},
            {[provider: "p", message_providers: [:a]], ~r/must be a map/},
            {[provider: "p", publish: true], ~r/publish: true requires :provider_version/}
          ] do
        assert_raise ArgumentError, message, fn -> Options.to_native(opts, 1) end
      end
    end
  end

  describe "verify/1" do
    @tag :tmp_dir
    test "no pacts: an error by default, ok when disabled", %{tmp_dir: dir} do
      assert {:error, %PactEx.VerificationError{exit_code: 0} = error} =
               Verifier.verify(provider: "p", dirs: [dir])

      assert Exception.message(error) =~ "no interaction"
      assert :ok = Verifier.verify(provider: "p", dirs: [dir], no_pacts_is_error: false)
    end

    @tag :tmp_dir
    test "a missing directory is an error even when no pacts are allowed", %{tmp_dir: dir} do
      missing = Path.join(dir, "missing")

      assert {:error, %PactEx.VerificationError{} = error} =
               Verifier.verify(provider: "p", dirs: [missing], no_pacts_is_error: false)

      assert Exception.message(error) =~ "missing"
    end

    @tag :tmp_dir
    test "an unreachable provider fails within the request timeout", %{tmp_dir: dir} do
      :ok = AnimalInteractions.write_consumer_pact(dir)

      {micros, result} =
        :timer.tc(fn ->
          Verifier.verify(
            provider: "animal_service",
            provider_url: "http://127.0.0.1:1",
            dirs: [dir],
            request_timeout: 1_000
          )
        end)

      assert {:error, %PactEx.VerificationError{}} = result
      assert micros < 30_000_000
    end

    test "an argument with a NUL byte raises PactEx.Error" do
      assert_raise PactEx.Error, ~r/NUL byte/, fn -> Verifier.verify(provider: "a\0b") end
    end

    test "a bad option raises before anything starts" do
      assert_raise ArgumentError, fn ->
        Verifier.verify(provider: "p", state_handler: :nope, dirs: ["x"])
      end
    end
  end
end
