defmodule PactEx.Acceptance.MessageProviderTest do
  use ExUnit.Case, async: false

  import PactEx.Matchers

  alias PactEx.{Message, Verifier}

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    pact = PactEx.new("animal_service", "weather_service", pact_dir: dir)

    message =
      "a weather data message"
      |> Message.new()
      |> Message.given("weather data for animals")
      |> Message.with_contents(%{"temperature" => like(23.0)})
      |> Message.with_metadata(%{"queue" => "weather"})

    :ok = Message.run(pact, message, fn _ -> :ok end)
    %{dir: dir}
  end

  defp verify(dir, providers, more \\ []) do
    Verifier.verify(
      [provider: "weather_service", dirs: [dir], message_providers: providers] ++ more
    )
  end

  test "verifies messages produced by Elixir functions", %{dir: dir} do
    providers = %{
      "a weather data message" => fn [%{name: "weather data for animals"}] ->
        {%{"temperature" => 19.5}, %{"queue" => "weather"}}
      end
    }

    assert :ok = verify(dir, providers)
  end

  test "a wrong message shape fails verification", %{dir: dir} do
    providers = %{
      "a weather data message" => fn _ -> {%{"temperature" => "hot"}, %{"queue" => "weather"}} end
    }

    assert {:error, %PactEx.VerificationError{} = error} = verify(dir, providers)
    assert Exception.message(error) =~ "a weather data message"
  end

  # The endpoint must run, so it gets a provider for another description and answers 404.
  # With `message_providers: %{}` no endpoint starts, and the test would pass on a refused
  # connection.
  test "a missing provider without fallback fails and names the description", %{dir: dir} do
    providers = %{"another message" => fn _ -> %{} end}

    assert {:error, %PactEx.VerificationError{} = error} = verify(dir, providers)
    assert Exception.message(error) =~ "a weather data message"
    assert error.callback_errors == ["no message provider for \"a weather data message\""]
  end

  test "the fallback provider answers any description", %{dir: dir} do
    fallback = fn _states -> {%{"temperature" => 1.5}, %{"queue" => "weather"}} end

    assert :ok =
             Verifier.verify(
               provider: "weather_service",
               dirs: [dir],
               fallback_message_provider: fallback
             )
  end

  test "a message provider that raises fails the verification and says why", %{dir: dir} do
    providers = %{"a weather data message" => fn _ -> raise "sensor offline" end}

    assert {:error, %PactEx.VerificationError{callback_errors: [reason]}} = verify(dir, providers)
    assert reason =~ "sensor offline"
  end
end
