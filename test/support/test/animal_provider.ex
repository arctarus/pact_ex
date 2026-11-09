defmodule PactEx.Test.AnimalProvider do
  @moduledoc """
  A provider for the animal service pact, for the verifier tests. It serves the
  endpoints of `PactEx.Test.AnimalInteractions` from an in-memory store that
  provider states fill. Test support only.
  """

  alias PactEx.Test.AnimalInteractions

  @type t :: %{port: pos_integer(), store: pid(), server: pid()}

  defmodule Router do
    @moduledoc false
    use Plug.Router

    plug(:match)
    plug(:dispatch)

    @impl Plug
    def init(opts), do: opts

    @impl Plug
    def call(conn, %{store: store} = opts),
      do: super(Plug.Conn.put_private(conn, :store, store), opts)

    get "/animals/:name" do
      case Agent.get(conn.private.store, &Map.fetch(&1, name)) do
        {:ok, animal} -> json(conn, 200, animal)
        :error -> json(conn, 404, %{"error" => "not_found"})
      end
    end

    get "/animals" do
      conn = Plug.Conn.fetch_query_params(conn)
      type = conn.query_params["type"]

      animals =
        conn.private.store
        |> Agent.get(&Map.values/1)
        |> Enum.filter(&(&1["type"] == type))

      json(conn, 200, %{"animals" => animals})
    end

    post "/animals" do
      Plug.Conn.send_resp(conn, 201, "")
    end

    match _ do
      json(conn, 404, %{"error" => "not_found"})
    end

    defp json(conn, status, body) do
      conn
      |> Plug.Conn.put_resp_content_type("application/json", nil)
      |> Plug.Conn.send_resp(status, JSON.encode!(body))
    end
  end

  @doc "Starts the provider on a free port of 127.0.0.1, with an empty store."
  @spec start() :: {:ok, t()} | {:error, term()}
  def start do
    with {:ok, store} <- Agent.start_link(fn -> %{} end),
         {:ok, server} <-
           Bandit.start_link(
             plug: {Router, %{store: store}},
             ip: {127, 0, 0, 1},
             port: 0,
             startup_log: false
           ),
         {:ok, {_ip, port}} <- ThousandIsland.listener_info(server) do
      {:ok, %{port: port, store: store, server: server}}
    else
      :error -> {:error, :no_listener}
      {:error, _reason} = error -> error
    end
  end

  @doc "Stops the provider. It is fine if it already stopped with its test."
  @spec stop(t()) :: :ok
  def stop(%{server: server, store: store}) do
    for pid <- [server, store] do
      try do
        GenServer.stop(pid)
      catch
        :exit, _already_stopped -> :ok
      end
    end

    :ok
  end

  @doc "Puts `animal` in the store, by its name."
  @spec put(t(), map()) :: :ok
  def put(%{store: store}, %{"name" => name} = animal) do
    Agent.update(store, &Map.put(&1, name, animal))
  end

  @doc """
  The state handler for the states of the animal pact. It puts Mary or Duke in
  the store, and does nothing for any other state or action.
  """
  @spec state_handler(t()) :: (String.t(), map(), :setup | :teardown -> :ok)
  def state_handler(provider) do
    fn
      "an alligator with the name Mary exists", _params, :setup ->
        put(provider, AnimalInteractions.mary_animal())

      "a dog with the name Duke exists", _params, :setup ->
        put(provider, AnimalInteractions.duke_animal())

      _state, _params, _action ->
        :ok
    end
  end
end
