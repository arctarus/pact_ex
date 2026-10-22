defmodule PactEx.Acceptance.HttpEndToEndTest do
  # Ports the consumer cases of pact_erlang's http_end_to_end_SUITE. The four
  # cases add to one pact file and the test checks the merged result, so they
  # run in one test: ExUnit runs tests in random order.
  use ExUnit.Case, async: true

  import PactEx.Matchers
  alias PactEx.{Consumer, HTTP}

  @consumer "animal_service_consumer"
  @provider "animal_service"

  @tag :tmp_dir
  test "four consumer interactions merge into one pact", %{tmp_dir: dir} do
    pact = PactEx.new(@consumer, @provider, pact_dir: dir)

    get_animal_mary(pact, dir)
    get_animal_miles(pact, dir)
    create_animal_max(pact, dir)
    find_all_alligators(pact, dir)

    assert Enum.sort(Enum.map(interactions(dir), & &1["description"])) == [
             "a request to GET a non-existing animal: Miles",
             "a request to GET an animal: Mary",
             "a request to create an animal: Max",
             "a request to find all alligators"
           ]
  end

  defp read_pact(dir) do
    dir |> Path.join("#{@consumer}-#{@provider}.json") |> File.read!() |> JSON.decode!()
  end

  defp interactions(dir), do: read_pact(dir)["interactions"]

  defp get_animal_mary(pact, dir) do
    animal = %{"name" => "Mary", "type" => "alligator"}

    interaction =
      HTTP.interaction("a request to GET an animal: Mary")
      |> HTTP.given("an alligator with the name Mary exists", animal)
      |> HTTP.with_request(:get, "/animals/Mary")
      |> HTTP.will_respond_with(200,
        headers: %{"Content-Type" => "application/json"},
        body: animal
      )

    assert :ok =
             Consumer.run(pact, [interaction], fn mock ->
               assert {:ok, ^animal} = AnimalClient.get_animal(mock.url, "Mary")
             end)

    written = Enum.find(interactions(dir), &(&1["description"] =~ "Mary"))

    assert [%{"name" => "an alligator with the name Mary exists", "params" => ^animal}] =
             written["providerStates"]
  end

  defp get_animal_miles(pact, dir) do
    interaction =
      HTTP.interaction("a request to GET a non-existing animal: Miles")
      |> HTTP.with_request(:get, regex("/animals/Miles", "^\\/animals\\/[a-zA-Z]+"))
      |> HTTP.will_respond_with(404,
        headers: %{"Content-Type" => "application/json"},
        body: %{"error" => "not_found"}
      )

    assert :ok =
             Consumer.run(pact, [interaction], fn mock ->
               assert {:error, :not_found} = AnimalClient.get_animal(mock.url, "Miles")
             end)

    written = Enum.find(interactions(dir), &(&1["description"] =~ "Miles"))
    assert written["request"]["matchingRules"]["path"]
  end

  defp create_animal_max(pact, dir) do
    pact_body =
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

    animal = %{
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

    interaction =
      HTTP.interaction("a request to create an animal: Max")
      |> HTTP.with_request(:post, "/animals",
        headers: %{"Content-Type" => "application/json"},
        body: pact_body
      )
      |> HTTP.will_respond_with(201)

    assert :ok =
             Consumer.run(pact, [interaction], fn mock ->
               assert :ok = AnimalClient.create_animal(mock.url, animal)
             end)

    written = Enum.find(interactions(dir), &(&1["description"] =~ "create an animal"))
    rules = written["request"]["matchingRules"]["body"]
    assert rules["$"]["matchers"]
    assert rules["$.gender"]
    assert rules["$.attributes"]
  end

  defp find_all_alligators(pact, dir) do
    result = %{"animals" => [%{"name" => "Mary", "type" => "alligator"}]}
    query = %{"type" => "alligator"}

    interaction =
      HTTP.interaction("a request to find all alligators")
      |> HTTP.given("an alligator with the name Mary exists")
      |> HTTP.with_request(:get, "/animals", query: query)
      |> HTTP.will_respond_with(200,
        headers: %{"Content-Type" => "application/json"},
        body: result
      )

    assert :ok =
             Consumer.run(pact, [interaction], fn mock ->
               assert {:ok, ^result} = AnimalClient.search_animals(mock.url, query)
             end)

    assert Enum.any?(
             interactions(dir),
             &(&1["description"] == "a request to find all alligators")
           )
  end
end
