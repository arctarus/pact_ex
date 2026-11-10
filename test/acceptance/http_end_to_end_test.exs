defmodule PactEx.Acceptance.HttpEndToEndTest do
  # Ports the consumer cases of pact_erlang's http_end_to_end_SUITE. The five
  # cases add to one pact file and the test checks the merged result, so they
  # run in one test: ExUnit runs tests in random order.
  #
  # Each case has a builder that returns the interaction and a step that runs
  # it against the mock server and checks what was written.
  use ExUnit.Case, async: true

  alias PactEx.Consumer
  alias PactEx.Test.AnimalInteractions

  @consumer "animal_service_consumer"
  @provider "animal_service"

  @mary AnimalInteractions.mary_animal()
  @duke AnimalInteractions.duke_animal()
  @alligators AnimalInteractions.alligators_body()

  @tag :tmp_dir
  test "five consumer interactions merge into one pact", %{tmp_dir: dir} do
    pact = PactEx.new(@consumer, @provider, pact_dir: dir)

    run_get_animal_mary(pact, dir)
    run_get_animal_duke(pact, dir)
    run_get_animal_miles(pact, dir)
    run_create_animal_max(pact, dir)
    run_find_all_alligators(pact, dir)

    assert Enum.sort(Enum.map(interactions(dir), & &1["description"])) == [
             "a request to GET a non-existing animal: Miles",
             "a request to GET an animal: Duke",
             "a request to GET an animal: Mary",
             "a request to create an animal: Max",
             "a request to find all alligators"
           ]
  end

  defp interactions(dir), do: PactFile.read!(dir, {@consumer, @provider})["interactions"]

  defp written(dir, description) do
    Enum.find(interactions(dir), &(&1["description"] == description))
  end

  # Run and assert steps.

  defp run_get_animal_mary(pact, dir) do
    interaction = AnimalInteractions.mary()

    assert :ok =
             Consumer.run(pact, [interaction], fn mock ->
               assert {:ok, @mary} = AnimalClient.get_animal(mock.url, "Mary")
             end)

    written = written(dir, interaction.description)

    assert [%{"name" => "an alligator with the name Mary exists", "params" => @mary}] =
             written["providerStates"]

    assert written["response"]["body"]["content"] == @mary
  end

  defp run_get_animal_duke(pact, dir) do
    interaction = AnimalInteractions.duke()

    assert :ok =
             Consumer.run(pact, [interaction], fn mock ->
               assert {:ok, @duke} = AnimalClient.get_animal(mock.url, "Duke")
             end)

    written = written(dir, interaction.description)
    assert [%{"name" => "a dog with the name Duke exists"} = state] = written["providerStates"]
    refute Map.has_key?(state, "params")
    assert written["response"]["headers"] == %{"Content-Type" => ["application/json"]}
    assert written["response"]["body"]["contentType"] == "application/json"
  end

  defp run_get_animal_miles(pact, dir) do
    interaction = AnimalInteractions.miles()

    assert :ok =
             Consumer.run(pact, [interaction], fn mock ->
               assert {:error, :not_found} = AnimalClient.get_animal(mock.url, "Miles")
             end)

    written = written(dir, interaction.description)

    assert written["request"]["matchingRules"]["path"]["matchers"] == [
             %{"match" => "regex", "regex" => "^\\/animals\\/[a-zA-Z]+"}
           ]

    assert written["response"]["status"] == 404
  end

  defp run_create_animal_max(pact, dir) do
    interaction = AnimalInteractions.max()

    assert :ok =
             Consumer.run(pact, [interaction], fn mock ->
               assert :ok = AnimalClient.create_animal(mock.url, AnimalInteractions.max_animal())
             end)

    rules = written(dir, interaction.description)["request"]["matchingRules"]["body"]
    type = %{"match" => "type"}
    min_one = %{"match" => "type", "min" => 1}

    assert rules["$"]["matchers"] == [type]
    assert rules["$.siblings"]["matchers"] == [min_one]
    assert rules["$.list_att"]["matchers"] == [min_one]
    assert rules["$.list_att[*][1]"]["matchers"] == [type]
    assert rules["$.children_details"]["matchers"] == [min_one]

    assert rules["$.gender"]["matchers"] == [%{"match" => "regex", "regex" => "(male|female)"}]

    assert rules["$.attributes"]["matchers"] == [
             %{
               "match" => "eachKey",
               "rules" => [%{"match" => "regex", "regex" => "(happy|ferocious)"}],
               "value" => ~s({"happy":true})
             }
           ]
  end

  defp run_find_all_alligators(pact, dir) do
    interaction = AnimalInteractions.alligators()

    assert :ok =
             Consumer.run(pact, [interaction], fn mock ->
               assert {:ok, @alligators} =
                        AnimalClient.search_animals(mock.url, %{"type" => "alligator"})
             end)

    written = written(dir, interaction.description)
    assert written["request"]["query"] == %{"type" => ["alligator"]}

    assert [%{"name" => "an alligator with the name Mary exists"} = state] =
             written["providerStates"]

    refute Map.has_key?(state, "params")
    assert written["response"]["body"]["content"] == @alligators
  end
end
