defmodule BaileysEx.Connection.Socket do
  @moduledoc """
  Connection state machine for the WebSocket and Noise transport lifecycle.

  The socket mirrors Baileys rc.9's `makeSocket` boundary: transport startup,
  Noise handshake, post-handshake frame IO, connection updates, keep-alive,
  unified session startup, routing updates, and explicit logout.
  """

  @behaviour :gen_statem

  alias BaileysEx.BinaryNode
  alias BaileysEx.Auth.Pairing
  alias BaileysEx.Auth.QR
  alias BaileysEx.Connection.Config
  alias BaileysEx.Connection.EventEmitter
  alias BaileysEx.Connection.Transport
  alias BaileysEx.Protocol.BinaryNode, as: BinaryNodeUtil
  alias BaileysEx.Protocol.Noise

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
          client_payload: binary() | nil,
          event_emitter: GenServer.server() | nil,
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
          server_time_offset_ms: integer()
        }

  @enforce_keys [:config, :auth_state, :transport_module, :transport_options]
  defstruct [
    :config,
    :auth_state,
    :client_payload,
    :event_emitter,
    :noise,
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

  @spec connect(GenServer.server()) :: :ok | {:error, {:invalid_state, state()}}
  def connect(server), do: :gen_statem.call(server, :connect)

  @spec disconnect(GenServer.server()) :: :ok
  def disconnect(server), do: :gen_statem.call(server, :disconnect)

  @spec logout(GenServer.server()) :: :ok | {:error, :not_connected}
  def logout(server), do: :gen_statem.call(server, :logout)

  @spec send_node(GenServer.server(), BinaryNode.t()) :: :ok | {:error, :not_connected | term()}
  def send_node(server, %BinaryNode{} = node), do: :gen_statem.call(server, {:send_node, node})

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

  @spec send_presence_update(GenServer.server(), presence_type()) ::
          :ok | {:error, :not_connected | term()}
  def send_presence_update(server, type) when type in [:available, :unavailable] do
    :gen_statem.call(server, {:send_presence_update, type})
  end

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
      event_emitter: Keyword.get(opts, :event_emitter),
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

  def authenticating(:info, :qr_refresh, data), do: refresh_pairing_qr(data)

  def authenticating(:info, message, data),
    do: handle_transport_message(:authenticating, message, data)

  def authenticating({:call, from}, request, data),
    do: handle_call(:authenticating, from, request, data)

  def authenticating(_event_type, _event, data), do: {:keep_state, data}

  def connected(:enter, _old_state, data) do
    {:keep_state, schedule_keep_alive(data)}
  end

  def connected(:info, {:query_timeout, query_id}, data),
    do: {:keep_state, expire_query(data, query_id)}

  def connected(:info, :keep_alive, data), do: send_keep_alive(data)
  def connected(:info, message, data), do: handle_transport_message(:connected, message, data)
  def connected({:call, from}, request, data), do: handle_call(:connected, from, request, data)
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

  defp handle_call(:connected, from, {:send_node, %BinaryNode{} = node}, data) do
    case send_node_internal(data, node) do
      {:ok, data} ->
        {:keep_state, data, [{:reply, from, :ok}]}

      {:error, reason, data} ->
        {:keep_state, data, [{:reply, from, {:error, reason}}]}
    end
  end

  defp handle_call(:connected, from, {:query, %BinaryNode{} = node, reply_to, timeout}, data)
       when is_integer(timeout) and timeout > 0 do
    {node, query_id} = ensure_query_id(node, data.pending_queries)

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

  defp apply_transport_event(:noise_handshake, {:binary, server_hello}, data) do
    case finish_noise_handshake(data, server_hello) do
      {:ok, data} -> {:ok, :authenticating, data}
      {:error, reason, data} -> {:error, reason, data}
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
        data = %{data | noise: noise, last_date_recv_at: System.monotonic_time(:millisecond)}
        apply_protocol_frames(current_state, frames, data)

      {:error, reason} ->
        {:error, reason, data}
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
         {:ok, data} <- do_send_transport_binary(%{data | noise: noise}, client_finish) do
      {:ok, %{data | last_date_recv_at: System.monotonic_time(:millisecond)}}
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

    case send_passive_iq(data, :active) do
      {:ok, data} ->
        emit_event(data, :connection_update, %{connection: :open})

        case send_unified_session(data) do
          {:ok, data} -> {:ok, :connected, data}
          {:error, reason, data} -> {:error, reason, data}
        end

      {:error, reason, data} ->
        {:error, reason, data}
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

  defp apply_binary_node(current_state, %BinaryNode{tag: "iq"} = node, data) do
    {:ok, current_state, maybe_resolve_query(data, node)}
  end

  defp apply_binary_node(current_state, _node, data), do: {:ok, current_state, data}

  defp apply_ib_node(current_state, node, data) do
    cond do
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
    last_date_recv_at = data.last_date_recv_at || System.monotonic_time(:millisecond)
    diff = System.monotonic_time(:millisecond) - last_date_recv_at

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
    case get_in(data.auth_state, [:creds, :me, :id]) do
      jid when is_binary(jid) ->
        case send_node_internal(data, logout_node(jid)) do
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
    auth_state_update = %{
      creds: %{me: Map.get(creds_update, :me)},
      account: Map.get(creds_update, :account),
      platform: Map.get(creds_update, :platform),
      signal_identities: Map.get(creds_update, :signal_identities)
    }

    data = %{data | auth_state: update_auth_state(data.auth_state, auth_state_update)}
    emit_event(data, :creds_update, creds_update)
    emit_event(data, :connection_update, %{is_new_login: true, qr: nil})

    with {:ok, data} <- send_node_internal(data, reply) do
      send_unified_session(data)
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
          |> Map.put(:next_qr_timeout_ms, 20_000)

        emit_event(data, :connection_update, %{qr: QR.generate(ref, data.auth_state)})

        {:ok, schedule_pairing_qr(data, 60_000)}
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
    if Noise.transport_ready?(noise) do
      case Noise.encode_frame(noise, payload) do
        {:ok, {noise, frame}} ->
          do_send_transport_binary(%{data | noise: noise}, frame)

        {:error, reason} ->
          {:error, reason, data}
      end
    else
      do_send_transport_binary(data, payload)
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

  defp fetch_client_payload(payload) when is_binary(payload), do: {:ok, payload}
  defp fetch_client_payload(_payload), do: {:error, :client_payload_not_configured}

  defp connection_failure(data, reason) do
    {:next_state, :disconnected, close_connection(data, reason)}
  end

  defp send_keep_alive_ping(data) do
    send_node_internal(data, keep_alive_node())
  end

  defp send_passive_iq(data, tag) when tag in [:active, :passive] do
    send_node_internal(data, passive_iq_node(tag))
  end

  defp send_unified_session(data) do
    send_node_internal(data, unified_session_node(data))
  end

  defp send_offline_batch(data) do
    send_node_internal(data, offline_batch_node())
  end

  defp send_presence_update_node(%__MODULE__{} = data, type)
       when type in [:available, :unavailable] do
    me = get_in(data.auth_state, [:creds, :me]) || %{}
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

  defp maybe_update_lid(data, nil), do: data

  defp maybe_update_lid(%__MODULE__{} = data, lid) when is_binary(lid) do
    creds_update = %{me: merge_maps(get_in(data.auth_state, [:creds, :me]) || %{}, %{lid: lid})}
    data = %{data | auth_state: update_auth_state(data.auth_state, %{creds: creds_update})}
    emit_event(data, :creds_update, creds_update)
    data
  end

  defp maybe_update_routing_info(%__MODULE__{} = data, edge_routing_node) do
    case edge_routing_node |> BinaryNodeUtil.child("routing_info") |> extract_binary_content() do
      routing_info when is_binary(routing_info) ->
        creds_update = %{routing_info: routing_info}
        data = %{data | auth_state: update_auth_state(data.auth_state, %{creds: creds_update})}
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

  defp update_auth_state(auth_state, updates) when is_map(auth_state) and is_map(updates) do
    merge_maps(auth_state, updates)
  end

  defp update_auth_state(_auth_state, updates), do: updates

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
        %{data | server_time_offset_ms: parsed * 1_000 - System.os_time(:millisecond)}

      _ ->
        data
    end
  end

  defp ensure_query_id(%BinaryNode{} = node, pending_queries) do
    existing_id = node.attrs["id"]

    query_id =
      if is_binary(existing_id) and existing_id != "" and
           not Map.has_key?(pending_queries, existing_id) do
        existing_id
      else
        generate_message_tag()
      end

    {%{node | attrs: Map.put(node.attrs, "id", query_id)}, query_id}
  end

  defp parse_dirty_update(%BinaryNode{attrs: attrs}) do
    %{type: attrs["type"], timestamp: parse_optional_integer(attrs["timestamp"])}
  end

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
      |> unified_session_id()
      |> Integer.to_string()

    %BinaryNode{
      tag: "ib",
      attrs: %{},
      content: [%BinaryNode{tag: "unified_session", attrs: %{"id" => session_id}, content: nil}]
    }
  end

  defp unified_session_id(server_time_offset_ms) do
    three_days_ms = 3 * 24 * 60 * 60 * 1_000
    week_ms = 7 * 24 * 60 * 60 * 1_000
    rem(System.os_time(:millisecond) + server_time_offset_ms + three_days_ms, week_ms)
  end

  defp keep_alive_node do
    %BinaryNode{
      tag: "iq",
      attrs: %{
        "id" => generate_message_tag(),
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

  defp passive_iq_node(tag) do
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

  defp logout_node(jid) do
    %BinaryNode{
      tag: "iq",
      attrs: %{
        "to" => @s_whatsapp_net,
        "type" => "set",
        "id" => generate_message_tag(),
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

  defp iq_result_node(message_id) when is_binary(message_id) do
    %BinaryNode{
      tag: "iq",
      attrs: %{"to" => @s_whatsapp_net, "type" => "result", "id" => message_id},
      content: nil
    }
  end

  defp generate_message_tag do
    System.unique_integer([:positive, :monotonic]) |> Integer.to_string()
  end
end
