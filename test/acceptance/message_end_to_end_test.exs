defmodule PactEx.Acceptance.MessageEndToEndTest do
  # Ports the consumer cases of pact_erlang's message_end_to_end_SUITE
  # (`animal_consume_message_1..4`). Each `Message.run/4` writes in merge mode,
  # so the four runs add up in one file. That is why it is one test with one
  # directory: ExUnit runs tests in random order, and each `:tmp_dir` is per test.
  use ExUnit.Case, async: true

  import PactEx.Matchers
  alias PactEx.Message

  setup_all do
    dir =
      Path.join(System.tmp_dir!(), "pact_ex_message_e2e_#{System.unique_integer([:positive])}")

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  test "four consumed messages end up in one pact", %{dir: dir} do
    pact = PactEx.new("animal_service", "weather_service", pact_dir: dir)

    # The four messages of pact_erlang animal_consume_message_1..4, in order.
    for msg <- animal_messages() do
      assert :ok =
               Message.run(pact, msg, fn %Message.Reified{contents: contents} ->
                 assert contents["weather"]["temperature"] == 23.0
                 assert contents["weather"]["humidity"] == 75.5
                 assert contents["weather"]["wind_speed_kmh"] == 29
                 assert contents["timestamp"] == "2024-03-14T10:22:13+05:30"
               end)
    end

    written = PactFile.read!(dir, {"animal_service", "weather_service"})
    interactions = written["interactions"]

    assert Enum.map(interactions, & &1["description"]) == [
             "a weather data message",
             "a weather data message 2",
             "a weather data message 3",
             "a weather data message 4"
           ]

    assert Enum.all?(interactions, &(&1["type"] == "Asynchronous/Messages"))

    assert Enum.map(interactions, & &1["providerStates"]) == [
             [%{"name" => "weather data for animals"}],
             [%{"name" => "weather data for animals 2"}],
             [%{"name" => "weather data for animals 3", "params" => %{"weather" => "cold"}}],
             nil
           ]

    assert Enum.all?(interactions, &Map.has_key?(&1["matchingRules"]["body"], "$"))
  end

  defp weather_body do
    like(%{
      "weather" => %{"temperature" => 23.0, "humidity" => 75.5, "wind_speed_kmh" => 29},
      "timestamp" => "2024-03-14T10:22:13+05:30"
    })
  end

  defp animal_messages do
    [
      Message.new("a weather data message")
      |> Message.given("weather data for animals")
      |> Message.with_contents(weather_body()),
      Message.new("a weather data message 2")
      |> Message.given("weather data for animals 2")
      |> Message.with_contents(weather_body()),
      Message.new("a weather data message 3")
      |> Message.given("weather data for animals 3", %{"weather" => "cold"})
      |> Message.with_contents(weather_body()),
      Message.new("a weather data message 4")
      |> Message.with_contents(weather_body())
    ]
  end
end
