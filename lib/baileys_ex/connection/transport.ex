defmodule BaileysEx.Connection.Transport do
  @moduledoc """
  Minimal transport behavior for the connection socket skeleton.

  The real Mint/WebSocket integration can satisfy this boundary in later
  work without changing the socket state contract introduced in this slice.
  """

  alias BaileysEx.Connection.Config

  @callback connect(Config.t(), term()) :: {:ok, term()} | {:error, term()}
  @callback disconnect(term()) :: :ok
  @callback send(term(), binary()) :: :ok | {:error, term()}

  defmodule Noop do
    @moduledoc false

    @behaviour BaileysEx.Connection.Transport

    @impl true
    def connect(_config, _opts), do: {:error, :transport_not_configured}

    @impl true
    def disconnect(_transport_state), do: :ok

    @impl true
    def send(_transport_state, _payload), do: {:error, :not_connected}
  end
end
