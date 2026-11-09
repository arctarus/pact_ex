defmodule PactEx.Test.AnimalInteractions do
  @moduledoc """
  The consumer interactions of the animal service, shared by the consumer and
  the provider acceptance tests. Test support only.
  """

  import PactEx.Matchers

  alias PactEx.{Consumer, HTTP}

  @consumer "animal_service_consumer"
  @provider "animal_service"

  @doc "The consumer name of the pact."
  @spec consumer() :: String.t()
  def consumer, do: @consumer

  @doc "The provider name of the pact."
  @spec provider() :: String.t()
  def provider, do: @provider

  @doc "The animal of the Mary interaction."
  @spec mary_animal() :: map()
  def mary_animal, do: %{"name" => "Mary", "type" => "alligator"}

  @doc "The animal of the Duke interaction."
  @spec duke_animal() :: map()
  def duke_animal, do: %{"name" => "Duke", "type" => "Dog"}

  @doc "The body of the alligators search."
  @spec alligators_body() :: map()
  def alligators_body, do: %{"animals" => [mary_animal()]}

  @doc "The mary interaction."
  @spec mary() :: PactEx.HTTP.Interaction.t()
  def mary do
    HTTP.interaction("a request to GET an animal: Mary")
    |> HTTP.given("an alligator with the name Mary exists", mary_animal())
    |> HTTP.with_request(:get, "/animals/Mary")
    |> HTTP.will_respond_with(200,
      headers: %{"Content-Type" => "application/json"},
      body: mary_animal()
    )
  end

  # The body is a pre-encoded JSON string, with its type in the header.
  @doc "The duke interaction."
  @spec duke() :: PactEx.HTTP.Interaction.t()
  def duke do
    HTTP.interaction("a request to GET an animal: Duke")
    |> HTTP.given("a dog with the name Duke exists")
    |> HTTP.with_request(:get, "/animals/Duke")
    |> HTTP.will_respond_with(200,
      headers: %{"Content-Type" => "application/json"},
      body: JSON.encode!(duke_animal())
    )
  end

  @doc "The miles interaction."
  @spec miles() :: PactEx.HTTP.Interaction.t()
  def miles do
    HTTP.interaction("a request to GET a non-existing animal: Miles")
    |> HTTP.with_request(:get, regex("/animals/Miles", "^\\/animals\\/[a-zA-Z]+"))
    |> HTTP.will_respond_with(404,
      headers: %{"Content-Type" => "application/json"},
      body: %{"error" => "not_found"}
    )
  end

  @doc "The max interaction."
  @spec max() :: PactEx.HTTP.Interaction.t()
  def max do
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

  @doc "The animal that the Max interaction sends."
  @spec max_animal() :: map()
  def max_animal do
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

  @doc "The alligators interaction."
  @spec alligators() :: PactEx.HTTP.Interaction.t()
  def alligators do
    HTTP.interaction("a request to find all alligators")
    |> HTTP.given("an alligator with the name Mary exists")
    |> HTTP.with_request(:get, "/animals", query: %{"type" => "alligator"})
    |> HTTP.will_respond_with(200,
      headers: %{"Content-Type" => "application/json"},
      body: alligators_body()
    )
  end

  @doc """
  Writes the consumer pact of all five interactions into `dir`, by running each
  one against a mock server with `AnimalClient`.
  """
  @spec write_consumer_pact(Path.t()) :: :ok
  def write_consumer_pact(dir) do
    pact = PactEx.new(@consumer, @provider, pact_dir: dir)

    run(pact, mary(), &AnimalClient.get_animal(&1, "Mary"))
    run(pact, duke(), &AnimalClient.get_animal(&1, "Duke"))
    run(pact, miles(), &AnimalClient.get_animal(&1, "Miles"))
    run(pact, max(), &AnimalClient.create_animal(&1, max_animal()))
    run(pact, alligators(), &AnimalClient.search_animals(&1, %{"type" => "alligator"}))
  end

  defp run(pact, interaction, request) do
    Consumer.run!(pact, [interaction], fn mock -> request.(mock.url) end)
  end
end
