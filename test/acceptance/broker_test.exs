defmodule PactEx.Acceptance.BrokerTest do
  use ExUnit.Case, async: false

  alias PactEx.Test.{AnimalInteractions, AnimalProvider, Broker}
  alias PactEx.Verifier

  @moduletag :broker
  @moduletag :tmp_dir

  defp publish(dir) do
    :ok = AnimalInteractions.write_consumer_pact(dir)
    version = "1.0.#{System.unique_integer([:positive])}"

    :ok =
      Broker.publish_pact(Path.join(dir, "animal_service_consumer-animal_service.json"), version)

    version
  end

  defp broker(selectors),
    do: [url: System.fetch_env!("PACT_BROKER_URL"), consumer_version_selectors: selectors]

  test "verifies pacts from the broker and publishes results", %{tmp_dir: dir} do
    version = publish(dir)
    {:ok, p} = AnimalProvider.start()

    try do
      assert :ok =
               Verifier.verify(
                 provider: "animal_service",
                 provider_url: "http://127.0.0.1:#{p.port}",
                 state_handler: AnimalProvider.state_handler(p),
                 broker: broker([%{"latest" => true}]),
                 publish: true,
                 provider_version: "2.0.0",
                 provider_branch: "main"
               )

      assert [%{"verificationResult" => %{"success" => true}} | _] =
               Broker.matrix("animal_service_consumer", version)
    after
      AnimalProvider.stop(p)
    end
  end

  # The pact is published first, so the provider exists and only the selector matches nothing.
  test "no_pacts_is_error applies when the broker returns no pacts", %{tmp_dir: dir} do
    publish(dir)
    broker = broker([%{"branch" => "no-such-branch"}])

    assert {:error, %PactEx.VerificationError{}} =
             Verifier.verify(provider: "animal_service", broker: broker)

    assert :ok =
             Verifier.verify(provider: "animal_service", broker: broker, no_pacts_is_error: false)
  end
end
