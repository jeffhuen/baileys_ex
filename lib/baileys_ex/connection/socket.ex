defmodule BaileysEx.Connection.Socket do
  @moduledoc """
  Connection state machine skeleton.

  This first slice owns the socket state contract and transport startup seam.
  The full Mint/WebSocket, Noise handshake, and auth runtime behavior will be
  layered onto this module in later connection work.
  """

  @behaviour :gen_statem

  alias BaileysEx.Connection.Config
  alias BaileysEx.Connection.Transport

  @type state ::
          :disconnected
          | :connecting
          | :noise_handshake
          | :authenticating
          | :connected
          | :reconnecting

  @type snapshot :: %{
          state: state(),
          retry_count: non_neg_integer(),
          buffer_size: non_neg_integer(),
          transport_connected?: boolean(),
          last_error: term()
        }

  @type t :: %__MODULE__{
          config: Config.t(),
          auth_state: term(),
          transport_module: module(),
          transport_options: term(),
          transport_state: term() | nil,
          buffer: binary(),
          retry_count: non_neg_integer(),
          epoch: non_neg_integer(),
          last_error: term()
        }

  @enforce_keys [:config, :auth_state, :transport_module, :transport_options]
  defstruct [
    :config,
    :auth_state,
    :transport_module,
    :transport_options,
    :transport_state,
    :last_error,
    buffer: <<>>,
    retry_count: 0,
    epoch: 0
  ]

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) when is_list(opts) do
    gen_statem_opts = Keyword.get(opts, :gen_statem_opts, [])

    case Keyword.fetch(opts, :name) do
      {:ok, name} ->
        :gen_statem.start_link(name, __MODULE__, opts, gen_statem_opts)

      :error ->
        :gen_statem.start_link(__MODULE__, opts, gen_statem_opts)
    end
  end

  @spec connect(GenServer.server()) :: :ok | {:error, {:invalid_state, state()}}
  def connect(server), do: :gen_statem.call(server, :connect)

  @spec disconnect(GenServer.server()) :: :ok
  def disconnect(server), do: :gen_statem.call(server, :disconnect)

  @spec state(GenServer.server()) :: state()
  def state(server), do: :gen_statem.call(server, :state)

  @spec snapshot(GenServer.server()) :: snapshot()
  def snapshot(server), do: :gen_statem.call(server, :snapshot)

  @spec send_payload(GenServer.server(), binary()) :: :ok | {:error, :not_connected | term()}
  def send_payload(server, payload) when is_binary(payload),
    do: :gen_statem.call(server, {:send_payload, payload})

  @impl true
  def callback_mode, do: [:state_functions, :state_enter]

  @impl true
  def init(opts) do
    {transport_module, transport_options} = Keyword.get(opts, :transport, {Transport.Noop, %{}})

    data = %__MODULE__{
      config: Keyword.get(opts, :config, Config.new()),
      auth_state: Keyword.get(opts, :auth_state),
      transport_module: transport_module,
      transport_options: transport_options
    }

    {:ok, :disconnected, data}
  end

  def disconnected(:enter, _old_state, data), do: {:keep_state, data}

  def disconnected({:call, from}, request, data),
    do: handle_call(:disconnected, from, request, data)

  def disconnected(_event_type, _event, data), do: {:keep_state, data}

  def connecting(:enter, _old_state, data), do: {:keep_state, data}

  def connecting(:internal, :establish_transport, data) do
    case data.transport_module.connect(data.config, data.transport_options) do
      {:ok, transport_state} ->
        {:next_state, :noise_handshake,
         %{data | transport_state: transport_state, last_error: nil}}

      {:error, reason} ->
        {:next_state, :disconnected,
         %{data | transport_state: nil, retry_count: data.retry_count + 1, last_error: reason}}
    end
  end

  def connecting({:call, from}, request, data), do: handle_call(:connecting, from, request, data)
  def connecting(_event_type, _event, data), do: {:keep_state, data}

  def noise_handshake(:enter, _old_state, data), do: {:keep_state, data}

  def noise_handshake({:call, from}, request, data),
    do: handle_call(:noise_handshake, from, request, data)

  def noise_handshake(_event_type, _event, data), do: {:keep_state, data}

  def authenticating(:enter, _old_state, data), do: {:keep_state, data}

  def authenticating({:call, from}, request, data),
    do: handle_call(:authenticating, from, request, data)

  def authenticating(_event_type, _event, data), do: {:keep_state, data}

  def connected(:enter, _old_state, data), do: {:keep_state, data}
  def connected({:call, from}, request, data), do: handle_call(:connected, from, request, data)
  def connected(_event_type, _event, data), do: {:keep_state, data}

  def reconnecting(:enter, _old_state, data), do: {:keep_state, data}

  def reconnecting({:call, from}, request, data),
    do: handle_call(:reconnecting, from, request, data)

  def reconnecting(_event_type, _event, data), do: {:keep_state, data}

  defp handle_call(current_state, from, :state, data) do
    {:keep_state, data, [{:reply, from, current_state}]}
  end

  defp handle_call(current_state, from, :snapshot, data) do
    {:keep_state, data, [{:reply, from, snapshot(current_state, data)}]}
  end

  defp handle_call(:disconnected, from, :connect, data) do
    {:next_state, :connecting, %{data | last_error: nil},
     [{:reply, from, :ok}, {:next_event, :internal, :establish_transport}]}
  end

  defp handle_call(current_state, from, :connect, data) do
    {:keep_state, data, [{:reply, from, {:error, {:invalid_state, current_state}}}]}
  end

  defp handle_call(_current_state, from, :disconnect, data) do
    disconnect_transport(data)
    {:next_state, :disconnected, %{data | transport_state: nil}, [{:reply, from, :ok}]}
  end

  defp handle_call(:connected, from, {:send_payload, payload}, data) do
    reply =
      case data.transport_module.send(data.transport_state, payload) do
        :ok -> :ok
        {:error, reason} -> {:error, reason}
      end

    {:keep_state, data, [{:reply, from, reply}]}
  end

  defp handle_call(_current_state, from, {:send_payload, _payload}, data) do
    {:keep_state, data, [{:reply, from, {:error, :not_connected}}]}
  end

  defp snapshot(current_state, data) do
    %{
      state: current_state,
      retry_count: data.retry_count,
      buffer_size: byte_size(data.buffer),
      transport_connected?: not is_nil(data.transport_state),
      last_error: data.last_error
    }
  end

  defp disconnect_transport(%__MODULE__{transport_state: nil}), do: :ok

  defp disconnect_transport(%__MODULE__{
         transport_module: transport_module,
         transport_state: transport_state
       }) do
    transport_module.disconnect(transport_state)
  end
end
