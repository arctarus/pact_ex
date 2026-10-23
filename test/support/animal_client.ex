defmodule AnimalClient do
  @moduledoc """
  Minimal HTTP client for a hypothetical animal service.

  Test support only. The acceptance tests point it at a Pact mock server to
  play the consumer side of the `animal_service` contract.

  Requests never retry, so a mismatch fails once instead of slowly.
  """

  @doc """
  Fetches `GET /animals/:name`.

  Returns `{:ok, body}` on 200 and `{:error, :not_found}` on 404.
  """
  @spec get_animal(String.t(), String.t()) :: {:ok, map()} | {:error, :not_found}
  def get_animal(base_url, name) do
    case Req.get!(base_url <> "/animals/" <> name, retry: false) do
      %{status: 200, body: body} -> {:ok, body}
      %{status: 404} -> {:error, :not_found}
    end
  end

  @doc """
  Sends `POST /animals` with `animal` as a JSON body.

  Returns `:ok` on 201.
  """
  @spec create_animal(String.t(), map()) :: :ok
  def create_animal(base_url, animal) when is_map(animal) do
    %{status: 201} = Req.post!(base_url <> "/animals", json: animal, retry: false)
    :ok
  end

  @doc """
  Fetches `GET /animals` with `query` as query parameters.

  Returns `{:ok, body}` on 200.
  """
  @spec search_animals(String.t(), map()) :: {:ok, map()}
  def search_animals(base_url, query) when is_map(query) do
    %{status: 200, body: body} =
      Req.get!(base_url <> "/animals", params: Map.to_list(query), retry: false)

    {:ok, body}
  end
end
