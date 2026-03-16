defmodule BaileysEx.Connection.Socket do
  @moduledoc """
  Connection state machine for the WebSocket and Noise transport lifecycle.

  The socket mirrors Baileys rc.9's `makeSocket` boundary: transport startup,
  Noise handshake, post-handshake frame IO, connection updates, keep-alive,
  unified session startup, routing updates, and explicit logout.
  """

  @behaviour :gen_statem

  alias BaileysEx.BinaryNode
  alias BaileysEx.Auth.ConnectionValidator
  alias BaileysEx.Auth.Pairing
  alias BaileysEx.Auth.Phone
  alias BaileysEx.Auth.QR
  alias BaileysEx.Auth.State, as: AuthState
  alias BaileysEx.Connection.Config
  alias BaileysEx.Connection.EventEmitter
  alias BaileysEx.Connection.Transport
  alias BaileysEx.Protocol.BinaryNode, as: BinaryNodeUtil
  alias BaileysEx.Protocol.Noise
  alias BaileysEx.Signal.PreKey
  alias BaileysEx.Signal.Store, as: SignalStore

  @s_whatsapp_net "s.whatsapp.net"

  @type state ::
          :disconnected
          | :connecting
          | :noise_handshake
          | :authenticating
          | :connected

  @type snapshot :: %{
          state: state(),
          retry_count: non_neg_integer(),
          buffer_size: non_neg_integer(),
          transport_connected?: boolean(),
          last_error: term()
        }

  @type presence_type :: :available | :unavailable

  @type t :: %__MODULE__{
          config: Config.t(),
          auth_state: term(),
          event_emitter: GenServer.server() | nil,
          signal_store: term(),
          task_supervisor: term(),
          noise_opts: keyword(),
          noise: Noise.t() | nil,
          transport_module: module(),
          transport_options: term(),
          transport_state: term() | nil,
          transport_connected?: boolean(),
          buffer: binary(),
          retry_count: non_neg_integer(),
          epoch: non_neg_integer(),
          last_error: term(),
          keep_alive_timer: reference() | nil,
          qr_timer: reference() | nil,
          last_date_recv_at: integer() | nil,
          qr_refs: [binary()],
          next_qr_timeout_ms: pos_integer(),
          pending_queries: %{optional(binary()) => {pid(), reference(), reference()}},
          server_time_offset_ms: integer(),
          clock_ms_fun: (-> integer()),
          monotonic_ms_fun: (-> integer()),
          message_tag_fun: (-> binary())
        }

  @enforce_keys [:config, :auth_state, :transport_module, :transport_options]
  defstruct [
    :config,
    :auth_state,
    :event_emitter,
    :signal_store,
    :noise,
    :task_supervisor,
    :transport_module,
    :transport_options,
    :transport_state,
    :last_error,
    :keep_alive_timer,
    :qr_timer,
    :last_date_recv_at,
    noise_opts: [],
    transport_connected?: false,
    buffer: <<>>,
    qr_refs: [],
    next_qr_timeout_ms: 20_000,
    pending_queries: %{},
    server_time_offset_ms: 0,
    clock_ms_fun: nil,
    monotonic_ms_fun: nil,
    message_tag_fun: nil,
    retry_count: 0,
    epoch: 0
  ]

  @doc """
  Starts the Socket GenStatem process.
  """
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

  @doc """
  Supervisor child specification override.
  """
  @spec child_spec(keyword()) :: Elixir.Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :permanent,
      shutdown: 5_000
    }
  end

  @doc """
  Commands the socket to establish a connection.
  """
  @spec connect(GenServer.server()) :: :ok | {:error, {:invalid_state, state()}}
  def connect(server), do: :gen_statem.call(server, :connect)

  @doc """
  Disconnects the active connection.
  """
  @spec disconnect(GenServer.server()) :: :ok
  def disconnect(server), do: :gen_statem.call(server, :disconnect)

  @doc """
  Logs out from the server and closes the connection.
  """
  @spec logout(GenServer.server()) :: :ok | {:error, :not_connected}
  def logout(server), do: :gen_statem.call(server, :logout)

  @doc """
  Requests a pairing code for a companion device linking flow.
  """
  @spec request_pairing_code(GenServer.server(), binary(), keyword()) ::
          {:ok, binary()} | {:error, :not_connected | term()}
  def request_pairing_code(server, phone_number, opts \\ [])
      when is_binary(phone_number) and is_list(opts) do
    :gen_statem.call(server, {:request_pairing_code, phone_number, opts})
  end

  @doc """
  Sends an outbound binary node to the server.
  """
  @spec send_node(GenServer.server(), BinaryNode.t()) :: :ok | {:error, :not_connected | term()}
  def send_node(server, %BinaryNode{} = node), do: :gen_statem.call(server, {:send_node, node})

  @doc """
  Performs an IQ query cycle and awaits the node response.
  """
  @spec query(GenServer.server(), BinaryNode.t(), timeout()) ::
          {:ok, BinaryNode.t()} | {:error, :not_connected | :timeout | term()}
  def query(server, %BinaryNode{} = node, timeout \\ 60_000)
      when is_integer(timeout) and timeout > 0 do
    ref = make_ref()

    case :gen_statem.call(server, {:query, node, {self(), ref}, timeout}, timeout + 1_000) do
      :ok ->
        receive do
          {__MODULE__, ^ref, result} -> result
        after
          timeout + 100 -> {:error, :timeout}
        end

      {:error, _reason} = error ->
        error
    end
  end

  @doc """
  Pushes a presence update to the network.
  """
  @spec send_presence_update(GenServer.server(), presence_type()) ::
          :ok | {:error, :not_connected | term()}
  def send_presence_update(server, type) when type in [:available, :unavailable] do
    :gen_statem.call(server, {:send_presence_update, type})
  end

  @doc "Send a WAM analytics buffer through the `w:stats` IQ path."
  @spec send_wam_buffer(GenServer.server(), binary()) ::
          {:ok, BinaryNode.t()} | {:error, :not_connected | :timeout | term()}
  def send_wam_buffer(server, wam_buffer) when is_binary(wam_buffer) do
    ref = make_ref()

    case :gen_statem.call(server, {:send_wam_buffer, wam_buffer, {self(), ref}, 60_000}, 61_000) do
      :ok ->
        receive do
          {__MODULE__, ^ref, result} -> result
        after
          60_100 -> {:error, :timeout}
        end

      {:error, _reason} = error ->
        error
    end
  end

  @doc """
  Returns the internal state of the state machine.
  """
  @spec state(GenServer.server()) :: state()
  def state(server), do: :gen_statem.call(server, :state)

  @doc """
  Exports a snapshot representation of the socket.
  """
  @spec snapshot(GenServer.server()) :: snapshot()
  def snapshot(server), do: :gen_statem.call(server, :snapshot)

  @doc """
  Bypass the protocol and send a raw binary payload.
  """
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
      event_emitter: Keyword.get(opts, :event_emitter),
      signal_store: Keyword.get(opts, :signal_store),
      task_supervisor: Keyword.get(opts, :task_supervisor),
      noise_opts: Keyword.get(opts, :noise_opts, []),
      transport_module: transport_module,
      transport_options: transport_options,
      clock_ms_fun: Keyword.get(opts, :clock_ms_fun, fn -> System.os_time(:millisecond) end),
      monotonic_ms_fun:
        Keyword.get(opts, :monotonic_ms_fun, fn -> System.monotonic_time(:millisecond) end),
      message_tag_fun:
        Keyword.get(opts, :message_tag_fun, fn ->
          System.unique_integer([:positive, :monotonic]) |> Integer.to_string()
        end)
    }

    {:ok, :disconnected, data}
  end

  @doc false
  def disconnected(:enter, _old_state, data), do: {:keep_state, data}

  @doc false
  def disconnected({:call, from}, request, data),
    do: handle_call(:disconnected, from, request, data)

  @doc false
  def disconnected(_event_type, _event, data), do: {:keep_state, data}

  @doc false
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

  @doc false
  def noise_handshake(:info, message, data),
    do: handle_transport_message(:noise_handshake, message, data)

  @doc false
  def noise_handshake({:call, from}, request, data),
    do: handle_call(:noise_handshake, from, request, data)

  @doc false
  def noise_handshake(_event_type, _event, data), do: {:keep_state, data}

  @doc false
  def authenticating(:enter, _old_state, data), do: {:keep_state, data}

  def authenticating(:info, {:internal_creds_update, creds_update}, data),
    do: {:keep_state, apply_internal_creds_update(data, creds_update)}

  def authenticating(:info, {:phone_pairing_finish_result, result, creds_update}, data),
    do: handle_phone_pairing_finish_result(result, creds_update, data)

  def authenticating(:info, {:post_auth_result, result}, data),
    do: handle_post_auth_result(result, data)

  def authenticating(:info, :qr_refresh, data), do: refresh_pairing_qr(data)

  def authenticating(:info, message, data),
    do: handle_transport_message(:authenticating, message, data)

  def authenticating({:call, from}, request, data),
    do: handle_call(:authenticating, from, request, data)

  def authenticating(_event_type, _event, data), do: {:keep_state, data}

  def connected(:enter, _old_state, data) do
    {:keep_state, schedule_keep_alive(data)}
  end

  def connected(:info, {:internal_creds_update, creds_update}, data),
    do: {:keep_state, apply_internal_creds_update(data, creds_update)}

  def connected(:info, {:query_timeout, query_id}, data),
    do: {:keep_state, expire_query(data, query_id)}

  def connected(:info, :keep_alive, data), do: send_keep_alive(data)
  @doc false
  def connected(:info, message, data), do: handle_transport_message(:connected, message, data)
  @doc false
  def connected({:call, from}, request, data), do: handle_call(:connected, from, request, data)
  @doc false
  def connected(_event_type, _event, data), do: {:keep_state, data}

  defp handle_call(current_state, from, :state, data) do
    {:keep_state, data, [{:reply, from, current_state}]}
  end

  defp handle_call(current_state, from, :snapshot, data) do
    {:keep_state, data, [{:reply, from, snapshot(current_state, data)}]}
  end

  defp handle_call(:disconnected, from, :connect, data) do
    emit_event(data, :connection_update, %{connection: :connecting})

    {:next_state, :connecting, %{data | last_error: nil, transport_connected?: false},
     [{:reply, from, :ok}, {:next_event, :internal, :establish_transport}]}
  end

  defp handle_call(current_state, from, :connect, data) do
    {:keep_state, data, [{:reply, from, {:error, {:invalid_state, current_state}}}]}
  end

  defp handle_call(_current_state, from, :disconnect, data) do
    data = close_connection(data, :disconnected, emit_close?: false, increment_retry?: false)
    {:next_state, :disconnected, data, [{:reply, from, :ok}]}
  end

  defp handle_call(:connected, from, :logout, data) do
    case logout_connection(data) do
      {:ok, data} ->
        {:next_state, :disconnected, data, [{:reply, from, :ok}]}

      {:error, reason, data} ->
        {:keep_state, data, [{:reply, from, {:error, reason}}]}
    end
  end

  defp handle_call(_current_state, from, :logout, data) do
    {:keep_state, data, [{:reply, from, {:error, :not_connected}}]}
  end

  defp handle_call(:connected, from, {:send_payload, payload}, data) do
    case send_transport_binary(data, payload) do
      {:ok, data} ->
        {:keep_state, data, [{:reply, from, :ok}]}

      {:error, reason, data} ->
        {:keep_state, data, [{:reply, from, {:error, reason}}]}
    end
  end

  defp handle_call(current_state, from, {:send_node, %BinaryNode{} = node}, data)
       when current_state in [:authenticating, :connected] do
    case send_node_internal(data, node) do
      {:ok, data} ->
        {:keep_state, data, [{:reply, from, :ok}]}

      {:error, reason, data} ->
        {:keep_state, data, [{:reply, from, {:error, reason}}]}
    end
  end

  defp handle_call(current_state, from, {:query, %BinaryNode{} = node, reply_to, timeout}, data)
       when current_state in [:authenticating, :connected] and is_integer(timeout) and
              timeout > 0 do
    {node, query_id} = ensure_query_id(node, data)

    case send_node_internal(data, node) do
      {:ok, data} ->
        data = register_pending_query(data, query_id, reply_to, timeout)
        {:keep_state, data, [{:reply, from, :ok}]}

      {:error, reason, data} ->
        {:keep_state, data, [{:reply, from, {:error, reason}}]}
    end
  end

  defp handle_call(:connected, from, {:send_presence_update, type}, data)
       when type in [:available, :unavailable] do
    case send_presence_update_node(data, type) do
      {:ok, data} ->
        {:keep_state, data, [{:reply, from, :ok}]}

      {:error, reason, data} ->
        {:keep_state, data, [{:reply, from, {:error, reason}}]}
    end
  end

  defp handle_call(:connected, from, {:send_wam_buffer, wam_buffer, reply_to, timeout}, data)
       when is_binary(wam_buffer) and is_integer(timeout) and timeout > 0 do
    {node, query_id} = ensure_query_id(wam_buffer_node(wam_buffer, data), data)

    case send_node_internal(data, node) do
      {:ok, data} ->
        data = register_pending_query(data, query_id, reply_to, timeout)
        {:keep_state, data, [{:reply, from, :ok}]}

      {:error, reason, data} ->
        {:keep_state, data, [{:reply, from, {:error, reason}}]}
    end
  end

  defp handle_call(:authenticating, from, {:request_pairing_code, phone_number, opts}, data)
       when is_binary(phone_number) and is_list(opts) do
    with {:ok, %{pairing_code: pairing_code, creds_update: creds_update, node: node}} <-
           Phone.build_pairing_request(phone_number, data.auth_state, data.config, opts),
         auth_state <- AuthState.merge_updates(data.auth_state, creds_update),
         data = %{data | auth_state: auth_state},
         :ok <- emit_event(data, :creds_update, creds_update),
         {:ok, data} <- send_node_internal(data, node) do
      {:keep_state, data, [{:reply, from, {:ok, pairing_code}}]}
    else
      {:error, reason, data} ->
        {:keep_state, data, [{:reply, from, {:error, reason}}]}

      {:error, reason} ->
        {:keep_state, data, [{:reply, from, {:error, reason}}]}
    end
  end

  defp handle_call(_current_state, from, {:send_payload, _payload}, data) do
    {:keep_state, data, [{:reply, from, {:error, :not_connected}}]}
  end

  defp handle_call(_current_state, from, {:send_node, %BinaryNode{}}, data) do
    {:keep_state, data, [{:reply, from, {:error, :not_connected}}]}
  end

  defp handle_call(_current_state, from, {:query, %BinaryNode{}, _reply_to, _timeout}, data) do
    {:keep_state, data, [{:reply, from, {:error, :not_connected}}]}
  end

  defp handle_call(_current_state, from, {:send_presence_update, _type}, data) do
    {:keep_state, data, [{:reply, from, {:error, :not_connected}}]}
  end

  defp handle_call(
         _current_state,
         from,
         {:send_wam_buffer, _wam_buffer, _reply_to, _timeout},
         data
       ) do
    {:keep_state, data, [{:reply, from, {:error, :not_connected}}]}
  end

  defp handle_call(_current_state, from, {:request_pairing_code, _phone_number, _opts}, data) do
    {:keep_state, data, [{:reply, from, {:error, :not_connected}}]}
  end

  defp snapshot(current_state, data) do
    %{
      state: current_state,
      retry_count: data.retry_count,
      buffer_size: buffer_size(data),
      transport_connected?: data.transport_connected?,
      last_error: data.last_error
    }
  end

  defp buffer_size(%__MODULE__{noise: %Noise{in_bytes: in_bytes}}) when is_binary(in_bytes),
    do: byte_size(in_bytes)

  defp buffer_size(%__MODULE__{buffer: buffer}) when is_binary(buffer), do: byte_size(buffer)

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
    data = %{data | transport_connected?: true}

    case start_noise_handshake(data) do
      {:ok, data} -> {:ok, :noise_handshake, data}
      {:error, reason, data} -> {:error, reason, data}
    end
  end

  defp apply_transport_event(:noise_handshake, {:binary, raw_payload}, data) do
    case Noise.decode_frames(data.noise, raw_payload) do
      {:ok, {noise, [server_hello]}} ->
        case finish_noise_handshake(%{data | noise: noise}, server_hello) do
          {:ok, data} -> {:ok, :authenticating, data}
          {:error, reason, data} -> {:error, reason, data}
        end

      {:ok, {_noise, []}} ->
        # Partial frame — buffer accumulated in noise state, wait for more data
        {:ok, :noise_handshake, data}

      {:error, reason} ->
        {:error, reason, data}
    end
  end

  defp apply_transport_event(
         current_state,
         {:binary, payload},
         %__MODULE__{noise: %Noise{} = noise} = data
       )
       when current_state in [:authenticating, :connected] do
    case Noise.decode_frames(noise, payload) do
      {:ok, {noise, frames}} ->
        data = %{data | noise: noise, last_date_recv_at: monotonic_ms(data)}
        apply_protocol_frames(current_state, frames, data)

      {:error, reason} ->
        {:error, reason, data}
    end
  end

  defp apply_transport_event(_current_state, {:closed, reason}, data), do: {:error, reason, data}
  defp apply_transport_event(_current_state, {:error, reason}, data), do: {:error, reason, data}
  defp apply_transport_event(current_state, _event, data), do: {:ok, current_state, data}

  defp start_noise_handshake(data) do
    routing_info = AuthState.get(data.auth_state, :routing_info)
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

  defp finish_noise_handshake(data, server_hello) do
    with {:ok, noise_key_pair} <- fetch_noise_key_pair(data.auth_state),
         {:ok, client_payload} <-
           ConnectionValidator.generate_client_payload(data.auth_state, data.config),
         {:ok, noise} <- Noise.process_server_hello(data.noise, server_hello, noise_key_pair),
         {:ok, {noise, client_finish}} <- Noise.client_finish(noise, client_payload),
         {:ok, %{noise: noise} = data} <-
           send_transport_binary(%{data | noise: noise}, client_finish),
         {:ok, noise} <- Noise.finish_init(noise) do
      {:ok, %{data | noise: noise, last_date_recv_at: monotonic_ms(data)}}
    else
      {:error, reason, data} -> {:error, reason, data}
      {:error, reason} -> {:error, reason, data}
    end
  end

  defp apply_protocol_frames(current_state, frames, data) do
    Enum.reduce_while(frames, {:ok, current_state, data}, fn frame, {:ok, state, data} ->
      case apply_protocol_frame(state, frame, data) do
        {:ok, next_state, data} ->
          {:cont, {:ok, next_state, data}}

        {:error, reason, data} ->
          {:halt, {:error, reason, data}}
      end
    end)
  end

  defp apply_protocol_frame(current_state, frame, data) do
    case BinaryNodeUtil.decode(frame) do
      {:ok, node} ->
        apply_binary_node(current_state, node, data)

      {:error, reason} ->
        {:error, reason, data}
    end
  end

  defp apply_binary_node(:authenticating, %BinaryNode{tag: "success", attrs: attrs}, data) do
    data =
      data
      |> clear_pairing_qr()
      |> maybe_update_server_time_offset(attrs["t"])
      |> maybe_update_lid(attrs["lid"])

    case start_post_auth_sequence(data) do
      :ok -> {:ok, :authenticating, data}
      {:error, reason} -> {:error, reason, data}
    end
  end

  defp apply_binary_node(current_state, %BinaryNode{tag: "ib"} = node, data) do
    apply_ib_node(current_state, node, data)
  end

  defp apply_binary_node(:authenticating, %BinaryNode{tag: "iq"} = node, data) do
    cond do
      BinaryNodeUtil.child(node, "pair-device") ->
        handle_pair_device(node, data)

      BinaryNodeUtil.child(node, "pair-success") ->
        handle_pair_success(node, data)

      true ->
        {:ok, :authenticating, maybe_resolve_query(data, node)}
    end
  end

  defp apply_binary_node(:authenticating, %BinaryNode{tag: "notification"} = node, data),
    do: apply_notification_node(:authenticating, node, data)

  defp apply_binary_node(:connected, %BinaryNode{tag: "notification"} = node, data),
    do: apply_notification_node(:connected, node, data)

  defp apply_binary_node(current_state, %BinaryNode{tag: tag} = node, data)
       when tag in ["message", "receipt", "ack"] do
    emit_event(data, :socket_node, %{node: node, state: current_state})
    {:ok, current_state, data}
  end

  defp apply_binary_node(current_state, %BinaryNode{tag: "iq"} = node, data) do
    {:ok, current_state, maybe_resolve_query(data, node)}
  end

  defp apply_binary_node(_current_state, %BinaryNode{tag: "stream:error"} = node, data),
    do: {:error, stream_error_reason(node), data}

  defp apply_binary_node(_current_state, %BinaryNode{tag: "failure"} = node, data),
    do: {:error, failure_reason(node), data}

  defp apply_binary_node(current_state, _node, data), do: {:ok, current_state, data}

  defp apply_ib_node(current_state, node, data) do
    cond do
      BinaryNodeUtil.child(node, "downgrade_webclient") ->
        {:error, :multidevice_mismatch, data}

      BinaryNodeUtil.child(node, "offline_preview") ->
        case send_offline_batch(data) do
          {:ok, data} -> {:ok, current_state, data}
          {:error, reason, data} -> {:error, reason, data}
        end

      BinaryNodeUtil.child(node, "offline") ->
        emit_event(data, :connection_update, %{received_pending_notifications: true})
        {:ok, current_state, data}

      edge_routing = BinaryNodeUtil.child(node, "edge_routing") ->
        data = maybe_update_routing_info(data, edge_routing)
        {:ok, current_state, data}

      dirty_node = BinaryNodeUtil.child(node, "dirty") ->
        emit_event(data, :dirty_update, parse_dirty_update(dirty_node))
        {:ok, current_state, data}

      true ->
        {:ok, current_state, data}
    end
  end

  defp send_keep_alive(%__MODULE__{} = data) do
    interval = data.config.keep_alive_interval_ms
    last_date_recv_at = data.last_date_recv_at || monotonic_ms(data)
    diff = monotonic_ms(data) - last_date_recv_at

    if diff > interval + 5_000 do
      connection_failure(%{data | last_date_recv_at: last_date_recv_at}, :connection_lost)
    else
      case send_keep_alive_ping(%{data | keep_alive_timer: nil}) do
        {:ok, data} ->
          {:keep_state, schedule_keep_alive(data)}

        {:error, reason, data} ->
          connection_failure(data, reason)
      end
    end
  end

  defp schedule_keep_alive(%__MODULE__{} = data) do
    data
    |> cancel_keep_alive_timer()
    |> Map.put(
      :keep_alive_timer,
      Process.send_after(self(), :keep_alive, data.config.keep_alive_interval_ms)
    )
  end

  defp cancel_keep_alive_timer(%__MODULE__{keep_alive_timer: nil} = data), do: data

  defp cancel_keep_alive_timer(%__MODULE__{keep_alive_timer: timer} = data) do
    Process.cancel_timer(timer)
    %{data | keep_alive_timer: nil}
  end

  defp logout_connection(%__MODULE__{} = data) do
    case me_id(data.auth_state) do
      jid when is_binary(jid) ->
        case send_node_internal(data, logout_node(jid, data)) do
          {:ok, data} ->
            data = close_connection(data, :logged_out, increment_retry?: false)
            {:ok, data}

          {:error, reason, data} ->
            {:error, reason, data}
        end

      _ ->
        data = close_connection(data, :logged_out, increment_retry?: false)
        {:ok, data}
    end
  end

  defp close_connection(%__MODULE__{} = data, reason, opts \\ []) do
    emit_close? = Keyword.get(opts, :emit_close?, true)
    increment_retry? = Keyword.get(opts, :increment_retry?, true)

    if emit_close? do
      emit_event(data, :connection_update, %{
        connection: :close,
        last_disconnect: %{reason: reason}
      })
    end

    disconnect_transport(data)

    data
    |> fail_pending_queries({:error, reason})
    |> clear_pairing_qr()
    |> then(fn data ->
      %{
        data
        | transport_state: nil,
          transport_connected?: false,
          noise: nil,
          retry_count: data.retry_count + if(increment_retry?, do: 1, else: 0),
          last_error: reason,
          last_date_recv_at: nil
      }
    end)
    |> cancel_keep_alive_timer()
  end

  defp handle_pair_device(%BinaryNode{attrs: attrs} = node, %__MODULE__{} = data) do
    with {:ok, data} <- send_node_internal(data, iq_result_node(attrs["id"])),
         {:ok, data} <- start_pairing_qr(data, node) do
      {:ok, :authenticating, data}
    else
      {:error, reason, data} -> {:error, reason, data}
      {:error, reason} -> {:error, reason, data}
    end
  end

  defp handle_pair_success(%BinaryNode{} = node, %__MODULE__{} = data) do
    data = data |> clear_pairing_qr() |> maybe_update_server_time_offset(node.attrs["t"])

    with {:ok, %{reply: reply, creds_update: creds_update}} <-
           Pairing.configure_successful_pairing(node, data.auth_state),
         {:ok, data} <-
           send_pair_success_reply(
             data,
             reply,
             creds_update
           ) do
      {:ok, :authenticating, data}
    else
      {:error, reason, data} -> {:error, reason, data}
      {:error, reason} -> {:error, reason, data}
    end
  end

  defp send_pair_success_reply(%__MODULE__{} = data, %BinaryNode{} = reply, creds_update) do
    data = %{data | auth_state: AuthState.merge_updates(data.auth_state, creds_update)}
    emit_event(data, :creds_update, creds_update)
    emit_event(data, :connection_update, %{is_new_login: true, qr: nil})

    with {:ok, data} <- send_node_internal(data, reply) do
      send_unified_session(data)
    end
  end

  defp handle_phone_pairing_notification(%BinaryNode{} = node, %__MODULE__{} = data) do
    socket_pid = self()

    with {:ok, %{creds_update: creds_update, node: finish_node}} <-
           Phone.complete_pairing(node, data.auth_state),
         :ok <-
           start_socket_task(data, fn ->
             result = query(socket_pid, finish_node, data.config.default_query_timeout_ms)

             Kernel.send(socket_pid, {:phone_pairing_finish_result, result, creds_update})
           end) do
      {:ok, :authenticating, data}
    else
      {:error, reason} -> {:error, reason, data}
    end
  end

  defp start_pairing_qr(%__MODULE__{} = data, %BinaryNode{} = node) do
    refs =
      node
      |> BinaryNodeUtil.child("pair-device")
      |> BinaryNodeUtil.children("ref")
      |> Enum.map(&extract_binary_content/1)
      |> Enum.filter(&is_binary/1)

    case refs do
      [] ->
        {:error, :missing_pairing_refs}

      [ref | remaining_refs] ->
        data =
          data
          |> clear_pairing_qr()
          |> Map.put(:qr_refs, remaining_refs)
          |> Map.put(:next_qr_timeout_ms, data.config.pairing_qr_refresh_timeout_ms)

        emit_event(data, :connection_update, %{qr: QR.generate(ref, data.auth_state)})

        {:ok, schedule_pairing_qr(data, data.config.pairing_qr_initial_timeout_ms)}
    end
  end

  defp refresh_pairing_qr(%__MODULE__{qr_refs: [ref | remaining_refs]} = data) do
    data = %{data | qr_timer: nil, qr_refs: remaining_refs}
    emit_event(data, :connection_update, %{qr: QR.generate(ref, data.auth_state)})
    {:keep_state, schedule_pairing_qr(data, data.next_qr_timeout_ms)}
  end

  defp refresh_pairing_qr(%__MODULE__{qr_refs: []} = data) do
    connection_failure(%{data | qr_timer: nil}, :qr_refs_exhausted)
  end

  defp schedule_pairing_qr(%__MODULE__{} = data, timeout_ms)
       when is_integer(timeout_ms) and timeout_ms > 0 do
    %{data | qr_timer: Process.send_after(self(), :qr_refresh, timeout_ms)}
  end

  defp clear_pairing_qr(%__MODULE__{qr_timer: nil} = data), do: %{data | qr_refs: []}

  defp clear_pairing_qr(%__MODULE__{qr_timer: qr_timer} = data) do
    Process.cancel_timer(qr_timer)
    %{data | qr_timer: nil, qr_refs: []}
  end

  defp send_transport_binary(%__MODULE__{noise: %Noise{} = noise} = data, payload)
       when is_binary(payload) do
    case Noise.encode_frame(noise, payload) do
      {:ok, {noise, frame}} ->
        do_send_transport_binary(%{data | noise: noise}, frame)

      {:error, reason} ->
        {:error, reason, data}
    end
  end

  defp send_transport_binary(%__MODULE__{} = data, payload) when is_binary(payload) do
    do_send_transport_binary(data, payload)
  end

  defp do_send_transport_binary(data, payload) do
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

  defp connection_failure(data, reason) do
    {:next_state, :disconnected, close_connection(data, reason)}
  end

  defp send_keep_alive_ping(data) do
    send_node_internal(data, keep_alive_node(data))
  end

  defp send_unified_session(data) do
    send_node_internal(data, unified_session_node(data))
  end

  defp send_offline_batch(data) do
    send_node_internal(data, offline_batch_node())
  end

  defp send_presence_update_node(%__MODULE__{} = data, type)
       when type in [:available, :unavailable] do
    me = AuthState.get(data.auth_state, :me, %{}) || %{}
    name = me[:name] || me["name"]

    if is_binary(name) and name != "" do
      emit_event(data, :connection_update, %{is_online: type == :available})

      with {:ok, data} <- maybe_send_presence_unified_session(data, type),
           do: send_node_internal(data, presence_node(name, type))
    else
      {:ok, data}
    end
  end

  defp maybe_send_presence_unified_session(data, :available), do: send_unified_session(data)
  defp maybe_send_presence_unified_session(data, :unavailable), do: {:ok, data}

  defp apply_notification_node(current_state, %BinaryNode{} = node, %__MODULE__{} = data) do
    result =
      cond do
        BinaryNodeUtil.child(node, "link_code_companion_reg") ->
          handle_phone_pairing_notification(node, data)

        low_prekey_count = encrypt_notification_count(node) ->
          _ = maybe_start_low_prekey_upload(data, low_prekey_count)
          {:ok, current_state, data}

        true ->
          {:ok, current_state, data}
      end

    maybe_emit_socket_node(result, node)
  end

  defp handle_phone_pairing_finish_result({:ok, _response}, creds_update, %__MODULE__{} = data) do
    data = %{data | auth_state: AuthState.merge_updates(data.auth_state, creds_update)}
    :ok = emit_event(data, :creds_update, creds_update)
    {:keep_state, data}
  end

  defp handle_phone_pairing_finish_result({:error, reason}, _creds_update, %__MODULE__{} = data) do
    connection_failure(data, reason)
  end

  defp handle_post_auth_result(:ok, %__MODULE__{} = data) do
    emit_event(data, :connection_update, %{connection: :open})

    case send_unified_session(data) do
      {:ok, data} -> {:next_state, :connected, data}
      {:error, reason, data} -> connection_failure(data, reason)
    end
  end

  defp handle_post_auth_result({:error, reason}, %__MODULE__{} = data) do
    connection_failure(data, reason)
  end

  defp apply_internal_creds_update(%__MODULE__{} = data, creds_update)
       when is_map(creds_update) do
    data = %{data | auth_state: AuthState.merge_updates(data.auth_state, creds_update)}
    :ok = emit_event(data, :creds_update, creds_update)
    data
  end

  defp start_post_auth_sequence(%__MODULE__{} = data) do
    socket_pid = self()

    start_socket_task(data, fn ->
      result =
        with :ok <- maybe_upload_post_auth_prekeys(data, socket_pid),
             {:ok, _response} <-
               query(
                 socket_pid,
                 passive_iq_node(:active, data),
                 data.config.default_query_timeout_ms
               ) do
          maybe_digest_post_auth_prekeys(data, socket_pid)
        end

      Kernel.send(socket_pid, {:post_auth_result, result})
    end)
  end

  defp maybe_upload_post_auth_prekeys(%__MODULE__{} = data, socket_pid) do
    case resolve_signal_store(data.signal_store) do
      %SignalStore{} = signal_store ->
        with {:ok, response} <-
               query(
                 socket_pid,
                 PreKey.available_prekeys_node(),
                 data.config.default_query_timeout_ms
               ),
             {:ok, count} <- PreKey.available_prekeys_count(response) do
          PreKey.maybe_upload_for_server_count(
            prekey_runtime_opts(data, signal_store, socket_pid),
            count
          )
        end

      _ ->
        :ok
    end
  end

  defp maybe_digest_post_auth_prekeys(%__MODULE__{} = data, socket_pid) do
    case resolve_signal_store(data.signal_store) do
      %SignalStore{} = signal_store ->
        PreKey.digest_key_bundle(prekey_runtime_opts(data, signal_store, socket_pid))

      _ ->
        :ok
    end
  end

  defp maybe_start_low_prekey_upload(%__MODULE__{} = data, count)
       when is_integer(count) and count >= 0 do
    socket_pid = self()

    case resolve_signal_store(data.signal_store) do
      %SignalStore{} = signal_store ->
        start_socket_task(data, fn ->
          _ =
            PreKey.maybe_upload_for_server_count(
              prekey_runtime_opts(data, signal_store, socket_pid),
              count
            )

          :ok
        end)

      _ ->
        :ok
    end
  end

  defp start_socket_task(%__MODULE__{} = data, fun) when is_function(fun, 0) do
    case data.task_supervisor do
      nil ->
        {:ok, _pid} = Task.start(fun)
        :ok

      task_supervisor ->
        case Task.Supervisor.start_child(task_supervisor, fun) do
          {:ok, _pid} -> :ok
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp prekey_runtime_opts(%__MODULE__{} = data, %SignalStore{} = signal_store, socket_pid) do
    [
      store: signal_store,
      auth_state: data.auth_state,
      query_fun: fn node -> query(socket_pid, node, data.config.default_query_timeout_ms) end,
      emit_creds_update: fn update ->
        Kernel.send(socket_pid, {:internal_creds_update, update})
        :ok
      end,
      upload_key: {:prekey_upload, socket_pid},
      upload_timeout_ms: 30_000
    ]
  end

  defp resolve_signal_store(nil), do: nil
  defp resolve_signal_store(%SignalStore{} = signal_store), do: signal_store

  defp resolve_signal_store({module, server}) when is_atom(module) do
    pid = GenServer.whereis(server)

    if is_pid(pid) and function_exported?(module, :wrap, 1) do
      %SignalStore{module: module, ref: module.wrap(pid)}
    else
      nil
    end
  end

  defp resolve_signal_store(_signal_store), do: nil

  defp encrypt_notification_count(%BinaryNode{attrs: %{"from" => @s_whatsapp_net}} = node) do
    case BinaryNodeUtil.child(node, "encrypt") |> BinaryNodeUtil.child("count") do
      %BinaryNode{attrs: %{"value" => value}} ->
        parse_optional_integer(value)

      _ ->
        nil
    end
  end

  defp encrypt_notification_count(_node), do: nil

  defp send_node_internal(data, %BinaryNode{} = node) do
    node
    |> BinaryNodeUtil.encode()
    |> then(&send_transport_binary(data, &1))
  end

  defp register_pending_query(%__MODULE__{} = data, query_id, {reply_pid, reply_ref}, timeout)
       when is_binary(query_id) and is_pid(reply_pid) and is_reference(reply_ref) do
    timer = Process.send_after(self(), {:query_timeout, query_id}, timeout)

    %{
      data
      | pending_queries: Map.put(data.pending_queries, query_id, {reply_pid, reply_ref, timer})
    }
  end

  defp expire_query(%__MODULE__{} = data, query_id) when is_binary(query_id) do
    case Map.pop(data.pending_queries, query_id) do
      {{reply_pid, reply_ref, _timer}, pending_queries} ->
        send_query_result(reply_pid, reply_ref, {:error, :timeout})
        %{data | pending_queries: pending_queries}

      {nil, _pending_queries} ->
        data
    end
  end

  defp maybe_resolve_query(%__MODULE__{} = data, %BinaryNode{attrs: %{"id" => query_id}} = node) do
    case Map.pop(data.pending_queries, query_id) do
      {{reply_pid, reply_ref, timer}, pending_queries} ->
        Process.cancel_timer(timer)
        send_query_result(reply_pid, reply_ref, query_result(node))
        %{data | pending_queries: pending_queries}

      {nil, _pending_queries} ->
        data
    end
  end

  defp maybe_resolve_query(%__MODULE__{} = data, _node), do: data

  defp query_result(%BinaryNode{} = node) do
    case BinaryNodeUtil.assert_error_free(node) do
      :ok -> {:ok, node}
      {:error, reason} -> {:error, reason}
    end
  end

  defp fail_pending_queries(%__MODULE__{} = data, result) do
    Enum.each(data.pending_queries, fn {_query_id, {reply_pid, reply_ref, timer}} ->
      Process.cancel_timer(timer)
      send_query_result(reply_pid, reply_ref, result)
    end)

    %{data | pending_queries: %{}}
  end

  defp send_query_result(reply_pid, reply_ref, result) do
    Kernel.send(reply_pid, {__MODULE__, reply_ref, result})
    :ok
  end

  defp emit_event(%__MODULE__{event_emitter: nil}, _event, _payload), do: :ok

  defp emit_event(%__MODULE__{event_emitter: event_emitter}, event, payload) do
    EventEmitter.emit(event_emitter, event, payload)
  catch
    :exit, _reason -> :ok
  end

  defp maybe_emit_socket_node({:ok, current_state, %__MODULE__{} = data}, %BinaryNode{} = node) do
    emit_event(data, :socket_node, %{node: node, state: current_state})
    {:ok, current_state, data}
  end

  defp maybe_emit_socket_node(result, _node), do: result

  defp maybe_update_lid(data, nil), do: data

  defp maybe_update_lid(%__MODULE__{} = data, lid) when is_binary(lid) do
    creds_update = %{me: merge_maps(AuthState.get(data.auth_state, :me, %{}) || %{}, %{lid: lid})}
    data = %{data | auth_state: AuthState.merge_updates(data.auth_state, creds_update)}
    emit_event(data, :creds_update, creds_update)
    data
  end

  defp maybe_update_routing_info(%__MODULE__{} = data, edge_routing_node) do
    case edge_routing_node |> BinaryNodeUtil.child("routing_info") |> extract_binary_content() do
      routing_info when is_binary(routing_info) ->
        creds_update = %{routing_info: routing_info}
        data = %{data | auth_state: AuthState.merge_updates(data.auth_state, creds_update)}
        emit_event(data, :creds_update, creds_update)
        data

      _ ->
        data
    end
  end

  defp extract_binary_content(nil), do: nil

  defp extract_binary_content(%BinaryNode{content: {:binary, binary}}) when is_binary(binary),
    do: binary

  defp extract_binary_content(%BinaryNode{content: binary}) when is_binary(binary), do: binary
  defp extract_binary_content(%BinaryNode{}), do: nil

  defp merge_maps(left, right) when is_map(left) and is_map(right) do
    Map.merge(left, right, fn _key, left_value, right_value ->
      if is_map(left_value) and is_map(right_value) do
        merge_maps(left_value, right_value)
      else
        right_value
      end
    end)
  end

  defp maybe_update_server_time_offset(%__MODULE__{} = data, nil), do: data

  defp maybe_update_server_time_offset(%__MODULE__{} = data, server_timestamp) do
    case Integer.parse(server_timestamp) do
      {parsed, ""} when parsed > 0 ->
        %{data | server_time_offset_ms: parsed * 1_000 - clock_ms(data)}

      _ ->
        data
    end
  end

  defp me_id(auth_state) do
    case AuthState.get(auth_state, :me) do
      %{id: jid} when is_binary(jid) -> jid
      %{"id" => jid} when is_binary(jid) -> jid
      _ -> nil
    end
  end

  defp ensure_query_id(%BinaryNode{} = node, %__MODULE__{} = data) do
    existing_id = node.attrs["id"]

    query_id =
      if is_binary(existing_id) and existing_id != "" and
           not Map.has_key?(data.pending_queries, existing_id) do
        existing_id
      else
        generate_message_tag(data)
      end

    {%{node | attrs: Map.put(node.attrs, "id", query_id)}, query_id}
  end

  defp parse_dirty_update(%BinaryNode{attrs: attrs}) do
    %{type: attrs["type"], timestamp: parse_optional_integer(attrs["timestamp"])}
  end

  defp stream_error_reason(%BinaryNode{attrs: attrs, content: content}) do
    reason =
      case List.first(List.wrap(content)) do
        %BinaryNode{tag: tag} when is_binary(tag) -> tag
        _ -> "unknown"
      end

    attrs
    |> Map.get("code")
    |> parse_optional_integer()
    |> disconnect_reason(reason)
  end

  defp failure_reason(%BinaryNode{attrs: attrs}) do
    attrs
    |> Map.get("reason")
    |> parse_optional_integer()
    |> disconnect_reason("failure")
  end

  defp disconnect_reason(nil, "conflict"), do: :connection_replaced
  defp disconnect_reason(440, _reason), do: :connection_replaced
  defp disconnect_reason(515, _reason), do: :restart_required
  defp disconnect_reason(411, _reason), do: :multidevice_mismatch
  defp disconnect_reason(401, _reason), do: :logged_out
  defp disconnect_reason(403, _reason), do: :forbidden
  defp disconnect_reason(503, _reason), do: :unavailable_service
  defp disconnect_reason(408, _reason), do: :connection_lost
  defp disconnect_reason(nil, _reason), do: :bad_session
  defp disconnect_reason(500, _reason), do: :bad_session
  defp disconnect_reason(code, reason) when is_integer(code), do: {:disconnect, code, reason}

  defp parse_optional_integer(nil), do: nil

  defp parse_optional_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} -> parsed
      _ -> nil
    end
  end

  defp unified_session_node(data) do
    session_id =
      data.server_time_offset_ms
      |> unified_session_id(data)
      |> Integer.to_string()

    %BinaryNode{
      tag: "ib",
      attrs: %{},
      content: [%BinaryNode{tag: "unified_session", attrs: %{"id" => session_id}, content: nil}]
    }
  end

  defp unified_session_id(server_time_offset_ms, data) do
    three_days_ms = 3 * 24 * 60 * 60 * 1_000
    week_ms = 7 * 24 * 60 * 60 * 1_000
    rem(clock_ms(data) + server_time_offset_ms + three_days_ms, week_ms)
  end

  defp keep_alive_node(data) do
    %BinaryNode{
      tag: "iq",
      attrs: %{
        "id" => generate_message_tag(data),
        "to" => @s_whatsapp_net,
        "type" => "get",
        "xmlns" => "w:p"
      },
      content: [%BinaryNode{tag: "ping", attrs: %{}, content: nil}]
    }
  end

  defp presence_node(name, type) do
    %BinaryNode{
      tag: "presence",
      attrs: %{"name" => String.replace(name, "@", ""), "type" => Atom.to_string(type)},
      content: nil
    }
  end

  defp passive_iq_node(tag, _data) do
    %BinaryNode{
      tag: "iq",
      attrs: %{
        "to" => @s_whatsapp_net,
        "type" => "set",
        "xmlns" => "passive"
      },
      content: [%BinaryNode{tag: Atom.to_string(tag), attrs: %{}, content: nil}]
    }
  end

  defp offline_batch_node do
    %BinaryNode{
      tag: "ib",
      attrs: %{},
      content: [%BinaryNode{tag: "offline_batch", attrs: %{"count" => "100"}, content: nil}]
    }
  end

  defp logout_node(jid, data) do
    %BinaryNode{
      tag: "iq",
      attrs: %{
        "to" => @s_whatsapp_net,
        "type" => "set",
        "id" => generate_message_tag(data),
        "xmlns" => "md"
      },
      content: [
        %BinaryNode{
          tag: "remove-companion-device",
          attrs: %{"jid" => jid, "reason" => "user_initiated"},
          content: nil
        }
      ]
    }
  end

  defp wam_buffer_node(wam_buffer, data) do
    timestamp =
      clock_ms(data)
      |> div(1_000)
      |> Integer.to_string()

    %BinaryNode{
      tag: "iq",
      attrs: %{
        "to" => @s_whatsapp_net,
        "xmlns" => "w:stats"
      },
      content: [
        %BinaryNode{tag: "add", attrs: %{"t" => timestamp}, content: {:binary, wam_buffer}}
      ]
    }
  end

  defp iq_result_node(message_id) when is_binary(message_id) do
    %BinaryNode{
      tag: "iq",
      attrs: %{"to" => @s_whatsapp_net, "type" => "result", "id" => message_id},
      content: nil
    }
  end

  defp generate_message_tag(data), do: data.message_tag_fun.()
  defp clock_ms(data), do: data.clock_ms_fun.()
  defp monotonic_ms(data), do: data.monotonic_ms_fun.()
end
