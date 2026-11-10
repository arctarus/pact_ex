defmodule PactEx.Acceptance.HttpProviderTest do
  use ExUnit.Case, async: false

  alias PactEx.Test.{AnimalInteractions, AnimalProvider}
  alias PactEx.Verifier

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    :ok = AnimalInteractions.write_consumer_pact(dir)
    {:ok, provider} = AnimalProvider.start()
    on_exit(fn -> AnimalProvider.stop(provider) end)
    %{dir: dir, provider: provider}
  end

  defp opts(dir, provider, more) do
    [provider: "animal_service", provider_url: "http://127.0.0.1:#{provider.port}", dirs: [dir]] ++
      more
  end

  test "verifies the animal pact with a state handler", %{dir: dir, provider: p} do
    assert :ok = Verifier.verify(opts(dir, p, state_handler: AnimalProvider.state_handler(p)))
  end

  test "verify!/1 raises the error, and returns :ok once the states are set up", %{
    dir: dir,
    provider: p
  } do
    assert_raise PactEx.VerificationError, ~r/Mary/, fn -> Verifier.verify!(opts(dir, p, [])) end
    assert :ok = Verifier.verify!(opts(dir, p, state_handler: AnimalProvider.state_handler(p)))
  end

  test "without the states the interactions that need them fail", %{dir: dir, provider: p} do
    assert {:error, %PactEx.VerificationError{exit_code: 1, report: report} = error} =
             Verifier.verify(opts(dir, p, []))

    assert report["result"] == false
    assert Exception.message(error) =~ "a request to GET an animal: Mary"
  end

  # A 5xx would be retried for about 127 s per state call. The 422 fails at once.
  test "a failing state handler fails verification quickly and names the reason", %{
    dir: dir,
    provider: p
  } do
    {micros, result} =
      :timer.tc(fn ->
        Verifier.verify(opts(dir, p, state_handler: fn _, _, _ -> {:error, :db_down} end))
      end)

    assert {:error, %PactEx.VerificationError{report: report} = error} = result
    assert report["result"] == false
    assert Exception.message(error) =~ ":db_down"
    assert micros < 10_000_000
  end

  test "a raising state handler does not crash the caller or leave the endpoint", %{
    dir: dir,
    provider: p
  } do
    parent = self()

    handler = fn _state, _params, _action ->
      # Bandit runs the handler in the process of the connection, so its socket
      # gives the port of the endpoint.
      send(parent, {:endpoint_port, local_port()})
      raise "boom"
    end

    assert {:error, %PactEx.VerificationError{callback_errors: [first | _]}} =
             Verifier.verify(opts(dir, p, state_handler: handler))

    assert first =~ "boom"
    refute_receive {:pact_ex_callback_error, _, _}

    assert_received {:endpoint_port, port}
    assert {:error, :econnrefused} = :gen_tcp.connect(~c"127.0.0.1", port, [], 1_000)
  end

  test "a handler without a catch-all clause still verifies interactions without states", %{
    dir: dir,
    provider: p
  } do
    handler = fn
      "an alligator with the name Mary exists", _params, :setup ->
        AnimalProvider.put(p, AnimalInteractions.mary_animal())

      "a dog with the name Duke exists", _params, :setup ->
        AnimalProvider.put(p, AnimalInteractions.duke_animal())
    end

    assert :ok = Verifier.verify(opts(dir, p, state_handler: handler))
  end

  defp local_port do
    [port] =
      for socket <- Port.list(),
          Port.info(socket, :connected) == {:connected, self()},
          {:ok, {_ip, port}} <- [:inet.sockname(socket)],
          do: port

    port
  end

  test "an external state_change_url is called instead of the handler", %{dir: dir, provider: p} do
    # The provider has no /_pact/state route, so each state change gets a 404
    # and fails the interaction. That is enough to see the URL is used.
    assert {:error, %PactEx.VerificationError{}} =
             Verifier.verify(opts(dir, p, state_change_url: "http://127.0.0.1:#{p.port}/states"))
  end
end
