defmodule BaileysEx.Connection.Transport do
  @moduledoc """
  Evented transport behaviour for the connection socket runtime.

  Transport implementations own HTTP and WebSocket connectivity and expose raw
  binary frame events back to the socket, which remains the owner of Noise and
  higher-level connection state.
  """

  alias BaileysEx.Connection.Config

  @type event :: :connected | {:binary, binary()} | {:closed, term()} | {:error, term()}

  @callback connect(Config.t(), term()) :: {:ok, term()} | {:error, term()}
  @callback handle_info(term(), term()) ::
              {:ok, term(), [event()]} | {:error, term(), term()} | :unknown
  @callback disconnect(term()) :: :ok
  @callback send_binary(term(), binary()) :: {:ok, term()} | {:error, term(), term()}

  defmodule Noop do
    @moduledoc false

    @behaviour BaileysEx.Connection.Transport

    @impl true
    def connect(_config, _opts), do: {:error, :transport_not_configured}

    @impl true
    def handle_info(_transport_state, _message), do: :unknown

    @impl true
    def disconnect(_transport_state), do: :ok

    @impl true
    def send_binary(transport_state, _payload), do: {:error, transport_state, :not_connected}
  end
end
