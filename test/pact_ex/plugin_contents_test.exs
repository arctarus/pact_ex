defmodule PactEx.PluginContentsTest do
  use ExUnit.Case, async: false

  alias PactEx.{Consumer, Consumer.Apply, HTTP, MockServer, Plugin}

  # Loads plugins. The driver's 60 s startup timeout must fire first; see test_helper.exs.
  @moduletag timeout: 120_000

  @entry_point "PactEx.Consumer.start_mock_server/3"

  defp interaction(body, opts \\ []) do
    "x"
    |> HTTP.interaction()
    |> HTTP.with_request(:get, "/x")
    |> HTTP.will_respond_with(200, [body: body] ++ opts)
  end

  defp protobuf(contents \\ %{"a" => 1}), do: Plugin.contents("application/protobuf", contents)

  # `[p]` keeps pgrep from matching its own command line.
  defp plugin_running? do
    {out, _status} = System.cmd("pgrep", ["-f", "[p]act-protobuf-plugin"])
    String.trim(out) != ""
  end

  defp wait_for_exit(attempts \\ 50) do
    cond do
      not plugin_running?() -> true
      attempts == 0 -> false
      true -> Process.sleep(100) && wait_for_exit(attempts - 1)
    end
  end

  describe "content type of plugin contents" do
    test "a Content-Type header for another media type is rejected" do
      i = interaction(protobuf(), headers: %{"content-type" => "text/plain"})

      assert {:error, %PactEx.Error{function: @entry_point, code: -101, message: message}} =
               Apply.validate(i)

      assert message =~ "text/plain"
    end

    test "the same media type is accepted in another case and with parameters" do
      assert :ok =
               "x"
               |> HTTP.interaction()
               |> HTTP.with_request(:get, "/x")
               |> HTTP.will_respond_with(200,
                 body: protobuf(),
                 content_type: "Application/Protobuf; charset=utf-8",
                 headers: %{"Content-Type" => "APPLICATION/PROTOBUF"}
               )
               |> Apply.validate()
    end

    test "a request body is checked like a response body" do
      i =
        "x"
        |> HTTP.interaction()
        |> HTTP.with_request(:post, "/x", body: protobuf(), content_type: "text/plain")

      assert {:error, %PactEx.Error{code: -101, message: message}} = Apply.validate(i)
      assert message =~ "request body"
    end
  end

  describe "the JSON of plugin contents" do
    test "an object that repeats a key is a -101 error" do
      i = interaction(protobuf(%{:a => 1, "a" => 2}))

      assert {:error, %PactEx.Error{function: @entry_point, code: -101, message: message}} =
               Apply.validate(i)

      assert message =~ "cannot encode"
    end

    test "a value that JSON cannot encode is a -101 error, not an exception" do
      i = interaction(protobuf(%{"a" => self()}))

      assert {:error, %PactEx.Error{function: @entry_point, code: -101}} = Apply.validate(i)
    end
  end

  describe "Plugin.installed?/2" do
    setup do
      previous = System.get_env("PACT_PLUGIN_DIR")

      dir =
        Path.join(System.tmp_dir!(), "pact_ex_installed_#{System.unique_integer([:positive])}")

      System.put_env("PACT_PLUGIN_DIR", dir)

      on_exit(fn ->
        File.rm_rf!(dir)

        if previous,
          do: System.put_env("PACT_PLUGIN_DIR", previous),
          else: System.delete_env("PACT_PLUGIN_DIR")
      end)

      %{dir: dir}
    end

    test "needs the plugin manifest in the plugin directory", %{dir: dir} do
      refute Plugin.installed?("demo", "1.0.0")

      File.mkdir_p!(Path.join(dir, "demo-1.0.0"))
      refute Plugin.installed?("demo", "1.0.0")

      File.write!(Path.join([dir, "demo-1.0.0", "pact-plugin.json"]), "{}")
      assert Plugin.installed?("demo", "1.0.0")
      refute Plugin.installed?("demo", "1.0.1")
    end
  end

  describe "load_all/2 and cleanup/1" do
    setup do
      previous = System.get_env("PACT_PLUGIN_DIR")

      missing =
        Path.join(System.tmp_dir!(), "pact_ex_no_plugins_#{System.unique_integer([:positive])}")

      System.put_env("PACT_PLUGIN_DIR", missing)

      on_exit(fn ->
        if previous,
          do: System.put_env("PACT_PLUGIN_DIR", previous),
          else: System.delete_env("PACT_PLUGIN_DIR")
      end)
    end

    test "load_all/2 with no plugins is :ok" do
      pact_ref = PactEx.Native.new_pact("c", "p")
      assert :ok = Plugin.load_all(pact_ref, PactEx.new("c", "p"))
      assert :ok = Plugin.cleanup(pact_ref)
    end

    test "load_all/2 returns the error of the first plugin that fails" do
      pact = "c" |> PactEx.new("p") |> PactEx.using_plugin("pact-ex-no-such-plugin", "9.9.9")
      pact_ref = PactEx.Native.new_pact("c", "p")

      assert {:error, %PactEx.Error{function: "pactffi_using_plugin", code: 2, message: message}} =
               Plugin.load_all(pact_ref, pact)

      assert message =~ "pact-ex-no-such-plugin"
      assert :ok = Plugin.cleanup(pact_ref)
      assert :ok = Plugin.cleanup(pact_ref)
    end

    test "start_mock_server/3 returns the load error and does not raise" do
      pact = "c" |> PactEx.new("p") |> PactEx.using_plugin("pact-ex-no-such-plugin", "9.9.9")

      assert {:error, %PactEx.Error{function: "pactffi_using_plugin", code: 2}} =
               Consumer.start_mock_server(pact, [interaction(nil)])
    end
  end

  describe "cleanup of the plugins of a pact" do
    # Counts the calls to `Plugin.cleanup/1` that this process makes. A process
    # cannot be its own tracer, so a helper process forwards the trace messages.
    setup do
      test = self()

      tracer =
        spawn_link(fn ->
          forward = fn forward ->
            receive do
              {:trace, ^test, :call, _mfa} -> send(test, :cleanup_called)
            end

            forward.(forward)
          end

          forward.(forward)
        end)

      :erlang.trace_pattern({PactEx.Plugin, :cleanup, 1}, true, [:local])
      :erlang.trace(test, true, [:call, tracer: tracer])

      on_exit(fn ->
        :erlang.trace_pattern({PactEx.Plugin, :cleanup, 1}, false, [:local])
      end)
    end

    defp cleanup_calls(count \\ 0) do
      receive do
        :cleanup_called -> cleanup_calls(count + 1)
      after
        100 -> count
      end
    end

    test "a pact that is rejected before it is created makes no call" do
      assert {:error, %PactEx.Error{code: -101}} =
               Consumer.start_mock_server(PactEx.new("c", "p"), [interaction(protobuf())])

      assert cleanup_calls() == 0
    end

    test "an error from load_all/2 cleans up once" do
      pact = "c" |> PactEx.new("p") |> PactEx.using_plugin("pact-ex-no-such-plugin", "9.9.9")

      assert {:error, %PactEx.Error{function: "pactffi_using_plugin"}} =
               Consumer.start_mock_server(pact, [interaction(nil)])

      assert cleanup_calls() == 1
    end

    test "an error while applying the interactions cleans up once" do
      bad = "x" |> HTTP.interaction() |> HTTP.with_request(:get, "/x\0y")

      assert {:error, %PactEx.Error{function: "pactffi_with_request", code: -100}} =
               Consumer.start_mock_server(PactEx.new("c", "p"), [bad])

      assert cleanup_calls() == 1
    end

    test "an error from create_mock_server cleans up once" do
      assert {:error, %PactEx.Error{function: "pactffi_create_mock_server_for_transport"}} =
               Consumer.start_mock_server(PactEx.new("c", "p"), [interaction(nil)],
                 host: "not an address"
               )

      assert cleanup_calls() == 1
    end

    test "an exception cleans up once and is re-raised" do
      bad = "x\0y" |> HTTP.interaction() |> HTTP.with_request(:get, "/x")

      assert_raise ArgumentError, fn ->
        Consumer.start_mock_server(PactEx.new("c", "p"), [bad])
      end

      assert cleanup_calls() == 1
    end

    test "a started server cleans up in stop/1, which stays idempotent" do
      assert {:ok, mock} = Consumer.start_mock_server(PactEx.new("c", "p"), [interaction(nil)])
      on_exit(fn -> MockServer.stop(mock) end)
      assert cleanup_calls() == 0

      assert :ok = MockServer.stop(mock)
      assert cleanup_calls() == 1

      assert :ok = MockServer.stop(mock)
    end
  end

  describe "with the protobuf plugin installed" do
    @describetag :plugin

    setup do
      # An earlier test of another module may have left a plugin running.
      assert wait_for_exit(), "a protobuf plugin process was already running"
      :ok
    end

    test "the plugin runs while the mock server lives and exits after stop/1" do
      pact = "c" |> PactEx.new("p") |> PactEx.using_plugin("protobuf", "0.8.1")

      assert {:ok, %MockServer{} = mock} = Consumer.start_mock_server(pact, [interaction(nil)])
      # A failed assert below must not leave the plugin loaded. `stop/1` is idempotent.
      on_exit(fn -> MockServer.stop(mock) end)
      assert plugin_running?()

      assert :ok = MockServer.stop(mock)
      assert wait_for_exit()
      assert :ok = MockServer.stop(mock)
    end

    test "a failure after the first plugin loaded unloads it" do
      pact =
        "c"
        |> PactEx.new("p")
        |> PactEx.using_plugin("protobuf", "0.8.1")
        |> PactEx.using_plugin("pact-ex-no-such-plugin", "9.9.9")

      assert {:error, %PactEx.Error{function: "pactffi_using_plugin"}} =
               Consumer.start_mock_server(pact, [interaction(nil)])

      assert wait_for_exit()
    end

    test "an interaction that fails to apply unloads the plugins" do
      pact = "c" |> PactEx.new("p") |> PactEx.using_plugin("protobuf", "0.8.1")

      bad = "x" |> HTTP.interaction() |> HTTP.with_request(:get, "/x\0y")

      assert {:error, %PactEx.Error{function: "pactffi_with_request", code: -100}} =
               Consumer.start_mock_server(pact, [bad])

      assert wait_for_exit()
    end

    test "a raise while starting unloads the plugins and re-raises" do
      pact = "c" |> PactEx.new("p") |> PactEx.using_plugin("protobuf", "0.8.1")

      # A NUL byte in the description raises once the plugin is loaded.
      bad = "x\0y" |> HTTP.interaction() |> HTTP.with_request(:get, "/x")

      assert_raise ArgumentError, fn -> Consumer.start_mock_server(pact, [bad]) end

      assert wait_for_exit()
    end
  end
end
