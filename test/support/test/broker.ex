defmodule PactEx.Test.Broker do
  @moduledoc """
  Calls the Pact Broker of the `:broker` tests (`PACT_BROKER_URL`). Test support
  only.
  """

  @doc """
  Publishes the pact file at `path` as `consumer_version` of its consumer.
  """
  @spec publish_pact(Path.t(), String.t()) :: :ok
  def publish_pact(path, consumer_version) do
    body = File.read!(path)

    %{"consumer" => %{"name" => consumer}, "provider" => %{"name" => provider}} =
      JSON.decode!(body)

    %{status: status} =
      Req.put!(
        "#{url()}/pacts/provider/#{provider}/consumer/#{consumer}/version/#{consumer_version}",
        body: body,
        headers: [{"content-type", "application/json"}],
        retry: false
      )

    true = status in [200, 201]
    :ok
  end

  @doc """
  The matrix of `consumer` at `version`: one row for each verification.
  """
  @spec matrix(String.t(), String.t()) :: [map()]
  def matrix(consumer, version) do
    %{status: 200, body: %{"matrix" => matrix}} =
      Req.get!("#{url()}/matrix",
        params: [{"q[][pacticipant]", consumer}, {"q[][version]", version}, {"latestby", "cvp"}],
        retry: false
      )

    matrix
  end

  defp url, do: System.fetch_env!("PACT_BROKER_URL")
end
