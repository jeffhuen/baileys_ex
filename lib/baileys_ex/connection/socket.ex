defmodule BaileysEx.Connection.Socket do
  @moduledoc """
  Connection state machine for the WebSocket and Noise transport lifecycle.

  The socket mirrors Baileys rc.9's `makeSocket` boundary: transport startup,
  Noise handshake, post-handshake frame IO, connection updates, keep-alive,
  unified session startup, routing updates, and explicit logout.
  """

  @behaviour :gen_statem

  alias BaileysEx.BinaryNode
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
          | :reconnecting

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
          last_date_recv_at: integer() | nil
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
    :last_date_recv_at,
    noise_opts: [],
    transport_connected?: false,
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

  def authenticating(:info, message, data),
    do: handle_transport_message(:authenticating, message, data)

  def authenticating({:call, from}, request, data),
    do: handle_call(:authenticating, from, request, data)

  def authenticating(_event_type, _event, data), do: {:keep_state, data}

  def connected(:enter, _old_state, data) do
    {:keep_state, schedule_keep_alive(data)}
  end

  def connected(:info, :keep_alive, data), do: send_keep_alive(data)
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
       when current_state in [:authenticating, :connected, :reconnecting] do
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
    data = maybe_update_lid(data, attrs["lid"])

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
        case send_node(data, logout_node(jid)) do
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

    %{
      data
      | transport_state: nil,
        transport_connected?: false,
        noise: nil,
        retry_count: data.retry_count + if(increment_retry?, do: 1, else: 0),
        last_error: reason,
        last_date_recv_at: nil
    }
    |> cancel_keep_alive_timer()
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
    send_node(data, keep_alive_node())
  end

  defp send_passive_iq(data, tag) when tag in [:active, :passive] do
    send_node(data, passive_iq_node(tag))
  end

  defp send_unified_session(data) do
    send_node(data, unified_session_node())
  end

  defp send_offline_batch(data) do
    send_node(data, offline_batch_node())
  end

  defp send_presence_update_node(%__MODULE__{} = data, type)
       when type in [:available, :unavailable] do
    me = get_in(data.auth_state, [:creds, :me]) || %{}
    name = me[:name] || me["name"]

    if is_binary(name) and name != "" do
      emit_event(data, :connection_update, %{is_online: type == :available})

      with {:ok, data} <- maybe_send_presence_unified_session(data, type),
           do: send_node(data, presence_node(name, type))
    else
      {:ok, data}
    end
  end

  defp maybe_send_presence_unified_session(data, :available), do: send_unified_session(data)
  defp maybe_send_presence_unified_session(data, :unavailable), do: {:ok, data}

  defp send_node(data, %BinaryNode{} = node) do
    node
    |> BinaryNodeUtil.encode()
    |> then(&send_transport_binary(data, &1))
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

  defp unified_session_node do
    %BinaryNode{
      tag: "ib",
      attrs: %{},
      content: [%BinaryNode{tag: "unified_session", attrs: %{}, content: nil}]
    }
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

  defp generate_message_tag do
    System.unique_integer([:positive, :monotonic]) |> Integer.to_string()
  end
end
