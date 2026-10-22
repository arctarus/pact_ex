defmodule PactEx.MockServerTest do
  use ExUnit.Case, async: true

  alias PactEx.{Consumer, HTTP, MockServer}

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    pact = PactEx.new("mock-consumer", "mock-provider", pact_dir: dir)

    i =
      HTTP.interaction("ping")
      |> HTTP.with_request(:get, "/ping")
      |> HTTP.will_respond_with(200, body: "pong")

    {:ok, mock} = Consumer.start_mock_server(pact, [i])
    on_exit(fn -> MockServer.stop(mock) end)
    %{mock: mock, pact_file: Path.join(dir, "mock-consumer-mock-provider.json")}
  end

  defp bad(value), do: Function.identity(value)

  test "matched?/1 and mismatches/1 follow the traffic", %{mock: mock} do
    refute MockServer.matched?(mock)

    assert [%{"type" => "missing-request", "method" => "GET", "path" => "/ping"}] =
             MockServer.mismatches(mock)

    assert %{body: "pong"} = Req.get!(mock.url <> "/ping")
    assert MockServer.matched?(mock)
    assert MockServer.mismatches(mock) == []

    Req.get!(mock.url <> "/other", retry: false)
    refute MockServer.matched?(mock)
    assert Enum.any?(MockServer.mismatches(mock), &(&1["type"] == "request-not-found"))
  end

  test "write_pact/2 writes the pact file", %{mock: mock, pact_file: file} do
    Req.get!(mock.url <> "/ping")
    assert :ok = MockServer.write_pact(mock)

    assert [%{"description" => "ping"}] =
             file |> File.read!() |> JSON.decode!() |> Map.fetch!("interactions")
  end

  test "write_pact/2 merges with an existing file by default", %{
    mock: mock,
    pact_file: file,
    tmp_dir: dir
  } do
    File.write!(
      file,
      JSON.encode!(%{
        "consumer" => %{"name" => "mock-consumer"},
        "provider" => %{"name" => "mock-provider"},
        "interactions" => [
          %{
            "type" => "Synchronous/HTTP",
            "description" => "older",
            "request" => %{"method" => "GET", "path" => "/older"},
            "response" => %{"status" => 200}
          }
        ],
        "metadata" => %{"pactSpecification" => %{"version" => "4.0"}}
      })
    )

    Req.get!(mock.url <> "/ping")
    assert :ok = MockServer.write_pact(mock)

    descriptions =
      dir
      |> Path.join("mock-consumer-mock-provider.json")
      |> File.read!()
      |> JSON.decode!()
      |> Map.fetch!("interactions")
      |> Enum.map(& &1["description"])
      |> Enum.sort()

    assert descriptions == ["older", "ping"]
  end

  test "write_pact/2 with overwrite: true replaces an existing file", %{
    mock: mock,
    pact_file: file
  } do
    File.write!(
      file,
      JSON.encode!(%{
        "consumer" => %{"name" => "mock-consumer"},
        "provider" => %{"name" => "mock-provider"},
        "interactions" => [
          %{
            "type" => "Synchronous/HTTP",
            "description" => "older",
            "request" => %{"method" => "GET", "path" => "/older"},
            "response" => %{"status" => 200}
          }
        ],
        "metadata" => %{"pactSpecification" => %{"version" => "4.0"}}
      })
    )

    Req.get!(mock.url <> "/ping")
    assert :ok = MockServer.write_pact(mock, overwrite: true)

    assert ["ping"] ==
             file
             |> File.read!()
             |> JSON.decode!()
             |> Map.fetch!("interactions")
             |> Enum.map(& &1["description"])
  end

  test "write_pact/2 rejects unknown options", %{mock: mock} do
    assert_raise ArgumentError, fn -> MockServer.write_pact(mock, bad(overwritee: true)) end
  end

  test "write_pact/2 rejects a non-boolean overwrite", %{mock: mock} do
    assert_raise ArgumentError, ~r/overwrite/, fn ->
      MockServer.write_pact(mock, bad(overwrite: "yes"))
    end
  end

  test "write_pact/2 returns a PactEx.Error when the directory cannot be created", %{
    mock: mock,
    tmp_dir: dir
  } do
    blocker = Path.join(dir, "blocker")
    File.write!(blocker, "x")

    assert {:error, %PactEx.Error{function: "pactffi_write_pact_file"}} =
             MockServer.write_pact(%{mock | pact_dir: blocker})
  end

  test "stop/1 shuts the server down and is idempotent", %{mock: mock} do
    assert :ok = MockServer.stop(mock)
    refute PactEx.Native.cleanup_mock_server(mock.port)
    assert :ok = MockServer.stop(mock)
    assert {:error, _} = Req.get(mock.url <> "/ping", retry: false)
  end

  test "after stop/1, queries return neutral values and write_pact/2 returns an error", %{
    mock: mock
  } do
    :ok = MockServer.stop(mock)
    refute MockServer.matched?(mock)
    assert MockServer.mismatches(mock) == []
    assert {:error, %PactEx.Error{code: 3}} = MockServer.write_pact(mock)
  end
end
