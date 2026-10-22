defmodule PactEx.Acceptance.HttpEndToEndTest do
  # Ports the consumer cases of pact_erlang's http_end_to_end_SUITE. The five
  # cases add to one pact file and the test checks the merged result, so they
  # run in one test: ExUnit runs tests in random order.
  #
  # Each case has a builder that returns the interaction and a step that runs
  # it against the mock server and checks what was written.
  use ExUnit.Case, async: true

  import PactEx.Matchers
  alias PactEx.{Consumer, HTTP}

  @consumer "animal_service_consumer"
  @provider "animal_service"

  @mary %{"name" => "Mary", "type" => "alligator"}
  @duke %{"name" => "Duke", "type" => "Dog"}
  @alligators %{"animals" => [@mary]}

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

  # Interaction builders.

  defp mary_interaction do
    HTTP.interaction("a request to GET an animal: Mary")
    |> HTTP.given("an alligator with the name Mary exists", @mary)
    |> HTTP.with_request(:get, "/animals/Mary")
    |> HTTP.will_respond_with(200, headers: %{"Content-Type" => "application/json"}, body: @mary)
  end

  # The body is a pre-encoded JSON string, with its type in the header.
  defp duke_interaction do
    HTTP.interaction("a request to GET an animal: Duke")
    |> HTTP.given("a dog with the name Duke exists")
    |> HTTP.with_request(:get, "/animals/Duke")
    |> HTTP.will_respond_with(200,
      headers: %{"Content-Type" => "application/json"},
      body: JSON.encode!(@duke)
    )
  end

  defp miles_interaction do
    HTTP.interaction("a request to GET a non-existing animal: Miles")
    |> HTTP.with_request(:get, regex("/animals/Miles", "^\\/animals\\/[a-zA-Z]+"))
    |> HTTP.will_respond_with(404,
      headers: %{"Content-Type" => "application/json"},
      body: %{"error" => "not_found"}
    )
  end

  defp max_interaction do
    body =
      like(%{
        "name" => "Max",
        "type" => "dog",
        "age" => 3,
        "nickname" => "koko",
        "weight_kg" => 12.0,
        "gender" => regex("male", "(male|female)"),
        "carnivorous" => true,
        "siblings" => each_like("lola"),
        "list_att" => each_like([1, like("head")]),
        "children" => ["coco"],
        "children_details" =>
          each_like(%{"name" => "coco", "age" => 1, "body_size" => [3, 4, 5]}),
        "attributes" => each_key(%{"happy" => true}, "(happy|ferocious)")
      })

    HTTP.interaction("a request to create an animal: Max")
    |> HTTP.with_request(:post, "/animals",
      headers: %{"Content-Type" => "application/json"},
      body: body
    )
    |> HTTP.will_respond_with(201)
  end

  defp max_animal do
    %{
      "name" => "Max",
      "type" => "dog",
      "age" => 3,
      "nickname" => "lazgo",
      "weight_kg" => 10.0,
      "gender" => "male",
      "carnivorous" => true,
      "siblings" => ["lola", "mary"],
      "list_att" => [[2, "legs"]],
      "children" => ["coco"],
      "children_details" => [%{"name" => "coco", "age" => 1, "body_size" => [3, 4, 5]}],
      "attributes" => %{"ferocious" => false}
    }
  end

  defp alligators_interaction do
    HTTP.interaction("a request to find all alligators")
    |> HTTP.given("an alligator with the name Mary exists")
    |> HTTP.with_request(:get, "/animals", query: %{"type" => "alligator"})
    |> HTTP.will_respond_with(200,
      headers: %{"Content-Type" => "application/json"},
      body: @alligators
    )
  end

  # Run and assert steps.

  defp run_get_animal_mary(pact, dir) do
    interaction = mary_interaction()

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
    interaction = duke_interaction()

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
    interaction = miles_interaction()

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
    interaction = max_interaction()

    assert :ok =
             Consumer.run(pact, [interaction], fn mock ->
               assert :ok = AnimalClient.create_animal(mock.url, max_animal())
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

    assert [
             %{
               "match" => "eachKey",
               "rules" => [%{"match" => "regex", "regex" => "(happy|ferocious)"}]
             }
           ] =
             rules["$.attributes"]["matchers"]
  end

  defp run_find_all_alligators(pact, dir) do
    interaction = alligators_interaction()

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
