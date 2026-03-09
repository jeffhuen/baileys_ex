defmodule BaileysEx.Connection.Socket do
  @moduledoc """
  Connection state machine for the WebSocket and Noise transport lifecycle.

  The current implementation owns transport startup, the Baileys-style Noise
  handshake, and the transition into `:authenticating`. Later connection work
  will layer in auth validation, keep-alive, reconnect policy, and the runtime
  store and event infrastructure.
  """

  @behaviour :gen_statem

  alias BaileysEx.Connection.Config
  alias BaileysEx.Connection.Transport
  alias BaileysEx.Protocol.Noise

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
          client_payload: binary() | nil,
          noise_opts: keyword(),
          noise: Noise.t() | nil,
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
    :client_payload,
    :noise,
    :transport_module,
    :transport_options,
    :transport_state,
    :last_error,
    noise_opts: [],
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
      client_payload: Keyword.get(opts, :client_payload),
      noise_opts: Keyword.get(opts, :noise_opts, []),
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
        {:keep_state, %{data | transport_state: transport_state, last_error: nil}}

      {:error, reason} ->
        connection_failure(data, reason)
    end
  end

  def connecting(:info, message, data),
    do: handle_transport_message(:connecting, message, data)

  def connecting({:call, from}, request, data), do: handle_call(:connecting, from, request, data)
  def connecting(_event_type, _event, data), do: {:keep_state, data}

  def noise_handshake(:enter, _old_state, data), do: {:keep_state, data}

  def noise_handshake(:info, message, data),
    do: handle_transport_message(:noise_handshake, message, data)

  def noise_handshake({:call, from}, request, data),
    do: handle_call(:noise_handshake, from, request, data)

  def noise_handshake(_event_type, _event, data), do: {:keep_state, data}

  def authenticating(:enter, _old_state, data), do: {:keep_state, data}

  def authenticating(:info, message, data),
    do: handle_transport_message(:authenticating, message, data)

  def authenticating({:call, from}, request, data),
    do: handle_call(:authenticating, from, request, data)

  def authenticating(_event_type, _event, data), do: {:keep_state, data}

  def connected(:enter, _old_state, data), do: {:keep_state, data}
  def connected(:info, message, data), do: handle_transport_message(:connected, message, data)
  def connected({:call, from}, request, data), do: handle_call(:connected, from, request, data)
  def connected(_event_type, _event, data), do: {:keep_state, data}

  def reconnecting(:enter, _old_state, data), do: {:keep_state, data}

  def reconnecting(:info, message, data),
    do: handle_transport_message(:reconnecting, message, data)

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
    case data.transport_module.send_binary(data.transport_state, payload) do
      {:ok, transport_state} ->
        {:keep_state, %{data | transport_state: transport_state}, [{:reply, from, :ok}]}

      {:error, transport_state, reason} ->
        {:keep_state, %{data | transport_state: transport_state},
         [{:reply, from, {:error, reason}}]}
    end
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

  defp handle_transport_message(
         _current_state,
         _message,
         %__MODULE__{transport_state: nil} = data
       ) do
    {:keep_state, data}
  end

  defp handle_transport_message(current_state, message, data) do
    case data.transport_module.handle_info(data.transport_state, message) do
      {:ok, transport_state, events} ->
        data = %{data | transport_state: transport_state}

        case apply_transport_events(current_state, events, data) do
          {:ok, ^current_state, data} -> {:keep_state, data}
          {:ok, next_state, data} -> {:next_state, next_state, data}
          {:error, reason, data} -> connection_failure(data, reason)
        end

      {:error, transport_state, reason} ->
        connection_failure(%{data | transport_state: transport_state}, reason)

      :unknown ->
        {:keep_state, data}
    end
  end

  defp apply_transport_events(current_state, events, data) do
    Enum.reduce_while(events, {:ok, current_state, data}, fn event, {:ok, state, data} ->
      case apply_transport_event(state, event, data) do
        {:ok, next_state, data} -> {:cont, {:ok, next_state, data}}
        {:error, reason, data} -> {:halt, {:error, reason, data}}
      end
    end)
  end

  defp apply_transport_event(:connecting, :connected, data) do
    case start_noise_handshake(data) do
      {:ok, data} -> {:ok, :noise_handshake, data}
      {:error, reason, data} -> {:error, reason, data}
    end
  end

  defp apply_transport_event(:noise_handshake, {:binary, server_hello}, data) do
    case finish_noise_handshake(data, server_hello) do
      {:ok, data} -> {:ok, :authenticating, data}
      {:error, reason, data} -> {:error, reason, data}
    end
  end

  defp apply_transport_event(_current_state, {:closed, reason}, data), do: {:error, reason, data}
  defp apply_transport_event(_current_state, {:error, reason}, data), do: {:error, reason, data}
  defp apply_transport_event(current_state, _event, data), do: {:ok, current_state, data}

  defp start_noise_handshake(data) do
    routing_info = get_in(data.auth_state, [:creds, :routing_info])
    noise_opts = Keyword.put_new(data.noise_opts, :routing_info, routing_info)

    with {:ok, noise} <- Noise.new(noise_opts),
         {:ok, {noise, client_hello}} <- Noise.client_hello(noise),
         {:ok, data} <- send_transport_binary(%{data | noise: noise}, client_hello) do
      {:ok, data}
    else
      {:error, reason, data} -> {:error, reason, data}
      {:error, reason} -> {:error, reason, data}
    end
  end

  defp finish_noise_handshake(%__MODULE__{noise: nil}, _server_hello),
    do: {:error, :noise_not_initialized}

  defp finish_noise_handshake(data, server_hello) do
    with {:ok, noise_key_pair} <- fetch_noise_key_pair(data.auth_state),
         {:ok, client_payload} <- fetch_client_payload(data.client_payload),
         {:ok, noise} <- Noise.process_server_hello(data.noise, server_hello, noise_key_pair),
         {:ok, {noise, client_finish}} <- Noise.client_finish(noise, client_payload),
         {:ok, data} <- send_transport_binary(%{data | noise: noise}, client_finish) do
      {:ok, data}
    else
      {:error, reason, data} -> {:error, reason, data}
      {:error, reason} -> {:error, reason, data}
    end
  end

  defp send_transport_binary(data, payload) do
    case data.transport_module.send_binary(data.transport_state, payload) do
      {:ok, transport_state} ->
        {:ok, %{data | transport_state: transport_state}}

      {:error, transport_state, reason} ->
        {:error, reason, %{data | transport_state: transport_state}}
    end
  end

  defp fetch_noise_key_pair(%{noise_key: %{public: public, private: private} = key_pair})
       when is_binary(public) and is_binary(private),
       do: {:ok, key_pair}

  defp fetch_noise_key_pair(%{
         creds: %{noise_key: %{public: public, private: private} = key_pair}
       })
       when is_binary(public) and is_binary(private),
       do: {:ok, key_pair}

  defp fetch_noise_key_pair(_auth_state), do: {:error, :noise_key_not_configured}

  defp fetch_client_payload(payload) when is_binary(payload), do: {:ok, payload}
  defp fetch_client_payload(_payload), do: {:error, :client_payload_not_configured}

  defp connection_failure(data, reason) do
    disconnect_transport(data)

    {:next_state, :disconnected,
     %{
       data
       | transport_state: nil,
         noise: nil,
         retry_count: data.retry_count + 1,
         last_error: reason
     }}
  end
end
