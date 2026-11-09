if Code.ensure_loaded?(Bandit) do
  defmodule PactEx.Verifier.EndpointServer do
    @moduledoc false

    # Starts `PactEx.Verifier.Endpoint` on Bandit, bound to 127.0.0.1 on a port
    # the OS picks. It is linked to the caller, so it also stops if the caller
    # dies.

    alias PactEx.Verifier.Endpoint

    @type t :: %{pid: pid(), port: pos_integer()}

    @spec start(map() | keyword()) :: {:ok, t()} | {:error, term()}
    def start(opts) do
      with {:ok, pid} <-
             Bandit.start_link(
               plug: {Endpoint, opts},
               ip: {127, 0, 0, 1},
               port: 0,
               startup_log: false
             ),
           {:ok, {_ip, port}} <- ThousandIsland.listener_info(pid) do
        {:ok, %{pid: pid, port: port}}
      else
        :error -> {:error, :no_listener}
        {:error, _reason} = error -> error
      end
    end

    @spec stop(t()) :: :ok
    def stop(%{pid: pid}), do: Supervisor.stop(pid)
  end
end
