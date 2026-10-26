defmodule PactEx.LogTest do
  # The FFI logger is global for the whole OS process and can be applied only
  # once, so every test that touches it lives in this module. Only one test
  # applies a logger; the others fail before `pactffi_logger_apply`.
  use ExUnit.Case, async: false

  alias PactEx.{Error, HTTP, Log, Native}

  describe "init/1 validation" do
    test "invalid options raise ArgumentError" do
      assert_raise ArgumentError, fn -> Log.init(level: :loud) end
      assert_raise ArgumentError, fn -> Log.init(sink: :syslog) end
    end

    test "other malformed options raise ArgumentError" do
      assert_raise ArgumentError, ~r/level/, fn -> Log.init(level: "info") end
      assert_raise ArgumentError, ~r/sink/, fn -> Log.init(sink: {:file, 123}) end
      assert_raise ArgumentError, ~r/sink/, fn -> Log.init(sink: {:file, ""}) end
      assert_raise ArgumentError, ~r/sink/, fn -> Log.init(sink: {:file, <<255, 254>>}) end
      assert_raise ArgumentError, ~r/sink/, fn -> Log.init(sink: {:file, "   "}) end
      assert_raise ArgumentError, ~r/sink/, fn -> Log.init(sink: {:file, "\t\n"}) end
      assert_raise ArgumentError, ~r/sink/, fn -> Log.init(sink: {:file, " pact.log"}) end
      assert_raise ArgumentError, ~r/sink/, fn -> Log.init(sink: {:file, "pact.log "}) end
      assert_raise ArgumentError, ~r/sink/, fn -> Log.init(sink: "stdout") end
      assert_raise ArgumentError, fn -> Log.init(color: true) end
    end

    test "a path with a NUL byte returns an error without touching the logger" do
      assert {:error, %Error{function: "pactffi_logger_attach_sink", code: -100} = error} =
               Log.init(sink: {:file, "pact\0.log"})

      assert error.message =~ "NUL"
    end
  end

  describe "Native.init_logger/2" do
    test "raises ArgumentError for an unknown level or a non-string sink" do
      assert_raise ArgumentError, fn -> Native.init_logger("stdout", :loud) end
      assert_raise ArgumentError, fn -> Native.init_logger("stdout", "info") end
      assert_raise ArgumentError, fn -> Native.init_logger(:stdout, :info) end
    end

    test "rejects an unknown sink type (-4) before applying a logger" do
      assert {:error, %{function: "pactffi_logger_attach_sink", code: -4, message: message}} =
               Native.init_logger("syslog", :info)

      assert message =~ "syslog"
    end

    test "rejects a NUL byte in the sink (-100)" do
      assert {:error, %{function: "pactffi_logger_attach_sink", code: -100}} =
               Native.init_logger("file a\0b", :info)
    end
  end

  describe "init/1 file errors" do
    @describetag :tmp_dir

    test "a directory as the log file fails at attach time (-6)", %{tmp_dir: dir} do
      assert {:error, %Error{function: "pactffi_logger_attach_sink", code: -6} = error} =
               Log.init(sink: {:file, dir})

      assert error.message == "could not open log file #{dir}"
    end

    test "a file used as a parent directory fails at attach time (-6)", %{tmp_dir: dir} do
      parent = Path.join(dir, "not-a-dir")
      File.write!(parent, "")
      path = Path.join(parent, "pact.log")

      assert {:error, %Error{function: "pactffi_logger_attach_sink", code: -6} = error} =
               Log.init(sink: {:file, path})

      assert error.message == "could not open log file #{path}"
    end
  end

  @tag :tmp_dir
  test "file sink receives FFI logs and a second init is rejected", %{tmp_dir: dir} do
    # A failed attach happens before a logger is applied, so a later valid init
    # must still succeed. (pact_ffi creates missing parent directories, so the
    # failure here comes from a directory used as the log file.)
    assert {:error, %Error{function: "pactffi_logger_attach_sink", code: -6}} =
             Log.init(sink: {:file, dir})

    log = Path.join(dir, "logs/pact.log")
    assert Log.init(level: :debug, sink: {:file, log}) == :ok

    pact = PactEx.new("log-consumer", "log-provider", pact_dir: dir)

    i =
      HTTP.interaction("logged") |> HTTP.with_request(:get, "/l") |> HTTP.will_respond_with(200)

    :ok = PactEx.Consumer.run(pact, [i], fn m -> Req.get!(m.url <> "/l") end)

    assert File.regular?(Path.join(dir, "log-consumer-log-provider.json"))
    assert File.read!(log) =~ "DEBUG"
    assert Log.init(level: :info) == {:error, :already_initialized}

    assert Log.init(level: :info, sink: {:file, Path.join(dir, "other.log")}) ==
             {:error, :already_initialized}

    # An attach failure is still reported as such after a logger was applied,
    # because attaching happens before the apply check. This holds whatever the
    # test order, since it runs here, after the successful apply.
    assert {:error, %Error{function: "pactffi_logger_attach_sink", code: -6} = error} =
             Log.init(sink: {:file, dir})

    assert error.message == "could not open log file #{dir}"
  end
end
