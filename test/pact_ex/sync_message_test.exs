defmodule PactEx.SyncMessageTest do
  use ExUnit.Case, async: true
  import PactEx.Matchers
  alias PactEx.SyncMessage

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    %{pact: PactEx.new("sync-consumer", "sync-provider", pact_dir: dir)}
  end

  defp pact_file(dir), do: Path.join(dir, "sync-consumer-sync-provider.json")
  defp read_pact(dir), do: PactFile.read!(dir, {"sync-consumer", "sync-provider"})

  defp user_message do
    SyncMessage.new("get user")
    |> SyncMessage.with_request(%{"id" => 1})
    |> SyncMessage.will_respond_with(%{"name" => "Ann"})
  end

  describe "builders" do
    test "new/1 starts an empty sync message" do
      assert %SyncMessage{
               description: "get user",
               provider_states: [],
               request: nil,
               request_content_type: nil,
               responses: [],
               plugin_contents: nil
             } = SyncMessage.new("get user")
    end

    test "given/3 keeps the states in order" do
      sm =
        SyncMessage.new("get user")
        |> SyncMessage.given("one")
        |> SyncMessage.given("two", %{"a" => 1})

      assert sm.provider_states == [{"one", nil}, {"two", %{"a" => 1}}]
    end

    test "with_request/3 sets the request and its content type" do
      sm = SyncMessage.with_request(SyncMessage.new("m"), "id=1", content_type: "text/plain")
      assert sm.request == "id=1"
      assert sm.request_content_type == "text/plain"
    end

    test "will_respond_with/3 appends responses, each with its own content type" do
      sm =
        SyncMessage.new("m")
        |> SyncMessage.will_respond_with(%{"a" => 1}, content_type: "application/json")
        |> SyncMessage.will_respond_with(%{"b" => 2})

      assert sm.responses == [{%{"a" => 1}, "application/json"}, {%{"b" => 2}, nil}]
    end

    test "with_plugin_contents/2 sets the plugin contents" do
      contents = PactEx.Plugin.contents("application/protobuf", %{"a" => 1})

      assert SyncMessage.with_plugin_contents(SyncMessage.new("m"), contents).plugin_contents ==
               contents
    end

    test "builders raise ArgumentError on unknown options" do
      sm = SyncMessage.new("m")
      assert_raise ArgumentError, fn -> SyncMessage.with_request(sm, %{}, foo: 1) end
      assert_raise ArgumentError, fn -> SyncMessage.will_respond_with(sm, %{}, foo: 1) end
    end
  end

  describe "run/4" do
    test "JSON request/response sync message is generated and written", %{tmp_dir: dir} do
      pact = PactEx.new("sync-consumer", "sync-provider", pact_dir: dir)

      sm =
        SyncMessage.new("get user")
        |> SyncMessage.given("user 1 exists")
        |> SyncMessage.with_request(%{"id" => integer(1)})
        |> SyncMessage.will_respond_with(%{"name" => like("Ann")})

      assert :ok =
               SyncMessage.run(pact, sm, fn %SyncMessage.Generated{
                                              request: req,
                                              responses: [resp],
                                              transport: nil
                                            } ->
                 assert req == %{"id" => 1}
                 assert resp == %{"name" => "Ann"}
               end)

      written =
        dir |> Path.join("sync-consumer-sync-provider.json") |> File.read!() |> JSON.decode!()

      assert [%{"type" => "Synchronous/Messages"}] = written["interactions"]
    end

    test "provider states, matching rules and several responses reach the pact file", %{
      pact: pact,
      tmp_dir: dir
    } do
      sm =
        SyncMessage.new("list users")
        |> SyncMessage.given("users exist", %{"count" => 2})
        |> SyncMessage.with_request(%{"page" => integer(1)})
        |> SyncMessage.will_respond_with(%{"name" => like("Ann")})
        |> SyncMessage.will_respond_with(%{"name" => like("Bob")})

      assert :ok =
               SyncMessage.run(pact, sm, fn generated ->
                 assert generated.request == %{"page" => 1}
                 assert generated.responses == [%{"name" => "Ann"}, %{"name" => "Bob"}]
               end)

      assert [interaction] = read_pact(dir)["interactions"]
      assert interaction["description"] == "list users"

      assert [%{"name" => "users exist", "params" => %{"count" => 2}}] =
               interaction["providerStates"]

      assert [_, _] = interaction["response"]
      assert interaction["request"]["matchingRules"]["body"]["$.page"]
    end

    test "text and binary contents arrive as raw bytes", %{pact: pact} do
      binary = <<0, 1, 2, 255>>

      sm =
        SyncMessage.new("raw")
        |> SyncMessage.with_request("hello", content_type: "text/plain")
        |> SyncMessage.will_respond_with(binary, content_type: "application/octet-stream")

      assert :ok =
               SyncMessage.run(pact, sm, fn generated ->
                 assert generated.request == "hello"
                 assert generated.responses == [binary]
               end)
    end

    test "each response has its own content type", %{pact: pact, tmp_dir: dir} do
      sm =
        SyncMessage.new("mixed")
        |> SyncMessage.with_request(%{"id" => 1})
        |> SyncMessage.will_respond_with(%{"name" => like("Ann")})
        |> SyncMessage.will_respond_with(<<0, 255>>, content_type: "application/octet-stream")

      assert :ok =
               SyncMessage.run(pact, sm, fn generated ->
                 assert generated.responses == [%{"name" => "Ann"}, <<0, 255>>]
               end)

      assert [%{"response" => [json, binary]}] = read_pact(dir)["interactions"]
      assert json["contents"]["contentType"] == "application/json"
      assert json["contents"]["content"] == %{"name" => "Ann"}
      assert binary["contents"]["contentType"] == "application/octet-stream"
      assert binary["contents"]["encoded"] == "base64"
    end

    test "a sync message with no response is allowed", %{pact: pact} do
      sm = SyncMessage.new("fire") |> SyncMessage.with_request(%{"id" => 1})

      assert :ok = SyncMessage.run(pact, sm, fn generated -> assert generated.responses == [] end)
    end

    test "the return value of the function is ignored", %{pact: pact} do
      assert :ok = SyncMessage.run(pact, user_message(), fn _ -> {:error, :ignored} end)
    end

    test "runs of the same pact merge into one file", %{pact: pact, tmp_dir: dir} do
      assert :ok = SyncMessage.run(pact, user_message(), fn _ -> :ok end)

      other =
        SyncMessage.new("get account")
        |> SyncMessage.with_request(%{"id" => 2})
        |> SyncMessage.will_respond_with(%{"name" => "Bob"})

      assert :ok = SyncMessage.run(pact, other, fn _ -> :ok end)
      assert [_, _] = read_pact(dir)["interactions"]
    end

    test "an exception in the function writes nothing and re-raises with its stacktrace", %{
      pact: pact,
      tmp_dir: dir
    } do
      {error, stacktrace} =
        try do
          SyncMessage.run(pact, user_message(), fn _ -> raise "boom" end)
        rescue
          error -> {error, __STACKTRACE__}
        end

      assert %RuntimeError{message: "boom"} = error

      assert Enum.any?(stacktrace, fn {_m, _f, _a, info} ->
               info[:file] == ~c"test/pact_ex/sync_message_test.exs"
             end)

      refute File.exists?(pact_file(dir))
    end

    test "a throw in the function writes nothing and propagates", %{pact: pact, tmp_dir: dir} do
      assert catch_throw(SyncMessage.run(pact, user_message(), fn _ -> throw(:stop) end)) == :stop
      refute File.exists?(pact_file(dir))
    end

    test "a pact that is not V4 is rejected", %{tmp_dir: dir} do
      pact = PactEx.new("sync-consumer", "sync-provider", pact_dir: dir, spec: :v3)

      sm =
        SyncMessage.new("get user")
        |> SyncMessage.with_request(%{"id" => 1})
        |> SyncMessage.will_respond_with(%{"name" => "Ann"})

      assert {:error,
              %PactEx.Error{function: "PactEx.SyncMessage.run/4", code: -101, message: message}} =
               SyncMessage.run(pact, sm, fn _ -> flunk("the handler must not run") end)

      assert message =~ "V4"
      refute File.exists?(Path.join(dir, "sync-consumer-sync-provider.json"))
    end

    test "an empty request is rejected before any native call", %{tmp_dir: dir} do
      pact = PactEx.new("sync-consumer", "sync-provider", pact_dir: dir)

      for sm <- [
            SyncMessage.new("no request"),
            SyncMessage.new("empty request") |> SyncMessage.with_request("")
          ] do
        assert {:error, %PactEx.Error{function: "PactEx.SyncMessage.run/4", code: -101}} =
                 SyncMessage.run(pact, sm, fn _ -> flunk("the handler must not run") end)
      end
    end

    test "an empty response is rejected before any native call", %{tmp_dir: dir} do
      pact = PactEx.new("sync-consumer", "sync-provider", pact_dir: dir)
      sm = SyncMessage.new("get user") |> SyncMessage.with_request(%{"id" => 1})

      for empty <- [nil, ""] do
        sm =
          sm
          |> SyncMessage.will_respond_with(%{"name" => "Ann"})
          |> SyncMessage.will_respond_with(empty)

        assert {:error, %PactEx.Error{function: "PactEx.SyncMessage.run/4", code: -101}} =
                 SyncMessage.run(pact, sm, fn _ -> flunk("the handler must not run") end)
      end
    end

    test "a plugin that is declared twice is rejected before any native call", %{pact: pact} do
      # A missing plugin would fail with code 2 if the runner got as far as loading it.
      pact = %{pact | plugins: [{"pact-ex-no-such-plugin", nil}, {"pact-ex-no-such-plugin", nil}]}
      sm = SyncMessage.new("twice") |> SyncMessage.with_request(%{"a" => 1})

      assert {:error,
              %PactEx.Error{function: "PactEx.SyncMessage.run/4", code: -101, message: message}} =
               SyncMessage.run(pact, sm, fn _ -> flunk("the handler must not run") end)

      assert message =~ "more than once"
    end

    test "plugin contents in a pact without plugins are rejected before any native call", %{
      tmp_dir: dir
    } do
      pact = PactEx.new("sync-consumer", "sync-provider", pact_dir: dir)

      sm =
        SyncMessage.new("plugin")
        |> SyncMessage.with_plugin_contents(
          PactEx.Plugin.contents("application/protobuf", %{"a" => 1})
        )

      assert {:error,
              %PactEx.Error{function: "PactEx.SyncMessage.run/4", code: -101, message: message}} =
               SyncMessage.run(pact, sm, fn _ -> flunk("the handler must not run") end)

      assert message =~ "the sync message has plugin contents"
    end

    test "plugin contents need no request or response of their own", %{pact: pact} do
      # A missing plugin fails with code 2 only if the runner got past the checks and
      # started loading plugins.
      pact = PactEx.using_plugin(pact, "pact-ex-no-such-plugin", "9.9.9")

      sm =
        SyncMessage.with_plugin_contents(
          SyncMessage.new("plugin"),
          PactEx.Plugin.contents("application/protobuf", %{"a" => 1})
        )

      assert {:error, %PactEx.Error{function: "pactffi_using_plugin", code: 2}} =
               SyncMessage.run(pact, sm, fn _ -> flunk("the handler must not run") end)
    end

    test "a content type that names another media type than the plugin contents is rejected", %{
      pact: pact
    } do
      pact = PactEx.using_plugin(pact, "pact-ex-no-such-plugin", "9.9.9")
      contents = PactEx.Plugin.contents("application/protobuf", %{"a" => 1})

      for sm <- [
            SyncMessage.new("request")
            |> SyncMessage.with_request(%{}, content_type: "application/json"),
            SyncMessage.new("response")
            |> SyncMessage.will_respond_with(%{}, content_type: "application/json")
          ] do
        sm = SyncMessage.with_plugin_contents(sm, contents)

        assert {:error,
                %PactEx.Error{function: "PactEx.SyncMessage.run/4", code: -101, message: message}} =
                 SyncMessage.run(pact, sm, fn _ -> flunk("the handler must not run") end)

        assert message =~ "application/protobuf"
      end
    end

    test "input that cannot be encoded is rejected before any native call", %{pact: pact} do
      # A missing plugin would fail with code 2 if the runner got as far as loading it.
      pact = PactEx.using_plugin(pact, "pact-ex-no-such-plugin", "9.9.9")

      for sm <- [
            SyncMessage.with_request(user_message(), %{"a" => {1, 2}}),
            SyncMessage.will_respond_with(user_message(), %{"a" => {1, 2}}),
            SyncMessage.will_respond_with(user_message(), 42),
            SyncMessage.given(user_message(), "a state", %{:a => 1, "a" => 2}),
            SyncMessage.with_plugin_contents(
              SyncMessage.new("plugin"),
              PactEx.Plugin.contents("application/protobuf", %{:a => 1, "a" => 2})
            )
          ] do
        assert {:error, %PactEx.Error{function: "PactEx.SyncMessage.run/4", code: -101}} =
                 SyncMessage.run(pact, sm, fn _ -> flunk("the handler must not run") end)
      end
    end

    test "transport options of the wrong type raise before any native call", %{pact: pact} do
      # A missing plugin would fail with code 2 if the runner got as far as loading it.
      pact = PactEx.using_plugin(pact, "pact-ex-no-such-plugin", "9.9.9")
      run = fn opts -> SyncMessage.run(pact, user_message(), fn _ -> :ok end, opts) end

      for opts <- [
            [transport: :grpc],
            [transport: "grpc", port: -1],
            [transport: "grpc", port: 65_536],
            [transport: "grpc", port: "80"],
            [transport: "grpc", port: 1.5],
            [transport: "grpc", host: :localhost],
            [transport: "grpc", host: nil],
            [transport: "grpc", transport_config: [a: 1]],
            [transport: "grpc", transport_config: "{}"]
          ] do
        assert_raise ArgumentError, ~r/must be/, fn -> run.(opts) end
      end
    end

    test "transport options are not checked without a transport", %{pact: pact} do
      assert :ok =
               SyncMessage.run(pact, user_message(), fn _ -> :ok end,
                 port: "80",
                 host: nil,
                 transport_config: "x"
               )
    end

    test "a transport config that cannot be encoded is rejected before any native call", %{
      pact: pact
    } do
      pact = PactEx.using_plugin(pact, "pact-ex-no-such-plugin", "9.9.9")

      for config <- [%{"a" => {1, 2}}, %{:a => 1, "a" => 2}] do
        assert {:error, %PactEx.Error{function: "PactEx.SyncMessage.run/4", code: -101} = error} =
                 SyncMessage.run(pact, user_message(), fn _ -> flunk("must not run") end,
                   transport: "grpc",
                   transport_config: config
                 )

        assert error.message =~ "option :transport_config"
      end
    end

    test "a transport no plugin provides returns an error and does not run the function", %{
      pact: pact,
      tmp_dir: dir
    } do
      assert {:error, %PactEx.Error{}} =
               SyncMessage.run(pact, user_message(), fn _ -> flunk("must not run") end,
                 transport: "pact-ex-no-such-transport"
               )

      refute File.exists?(pact_file(dir))
    end

    test "options are validated", %{pact: pact} do
      assert_raise ArgumentError, fn ->
        SyncMessage.run(pact, user_message(), fn _ -> :ok end, foo: 1)
      end

      assert :ok =
               SyncMessage.run(pact, user_message(), fn _ -> :ok end,
                 host: "localhost",
                 port: 1234,
                 transport_config: %{"a" => 1}
               )
    end
  end

  describe "run!/4" do
    test "returns :ok and raises the error", %{pact: pact} do
      assert :ok = SyncMessage.run!(pact, user_message(), fn _ -> :ok end)

      assert_raise PactEx.Error, ~r/request/, fn ->
        SyncMessage.run!(pact, SyncMessage.new("empty"), fn _ -> :ok end)
      end
    end
  end
end
