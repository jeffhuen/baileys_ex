defmodule BaileysEx.Feature.Presence do
  @moduledoc """
  Presence helpers aligned with Baileys' presence and chatstate behavior.
  """

  alias BaileysEx.BinaryNode
  alias BaileysEx.Connection.EventEmitter
  alias BaileysEx.Connection.Socket
  import BaileysEx.Connection.TransportAdapter, only: [send_node: 2]
  alias BaileysEx.Feature.TcToken
  alias BaileysEx.Protocol.JID

  @typedoc "Presence states supported by Baileys."
  @type presence :: :unavailable | :available | :composing | :recording | :paused

  @typedoc "Parsed presence payload emitted through the event emitter."
  @type presence_update :: %{
          required(:id) => String.t(),
          required(:presences) => %{required(String.t()) => map()}
        }

  @doc """
  Send a Baileys-compatible presence or chatstate update.
  """
  @spec send_update(term(), presence(), String.t() | nil, keyword()) :: :ok | {:error, term()}
  def send_update(sendable, type, to_jid \\ nil, opts \\ [])

  def send_update(sendable, type, nil, opts) when type in [:available, :unavailable] do
    case sendable do
      fun when is_function(fun, 1) ->
        case opts[:name] do
          name when is_binary(name) and name != "" ->
            send_node(fun, availability_node(name, type))

          _ ->
            :ok
        end

      _ ->
        send_presence_update(sendable, type)
    end
  end

  def send_update(sendable, type, to_jid, opts)
      when type in [:composing, :recording, :paused] and is_binary(to_jid) do
    with {:ok, from_jid} <- chatstate_from_jid(to_jid, opts) do
      send_node(sendable, chatstate_node(from_jid, to_jid, type))
    end
  end

  @doc """
  Subscribe to presence updates for a JID, appending a TC token when one exists.
  """
  @spec subscribe(term(), String.t(), keyword()) :: :ok | {:error, term()}
  def subscribe(sendable, to_jid, opts \\ []) when is_binary(to_jid) and is_list(opts) do
    node = %BinaryNode{
      tag: "presence",
      attrs: %{
        "to" => to_jid,
        "id" => message_tag(opts),
        "type" => "subscribe"
      },
      content: TcToken.build_content(opts[:signal_store], to_jid)
    }

    send_node(sendable, node)
  end

  @doc """
  Parse an incoming presence or chatstate node and optionally emit `presence_update`.
  """
  @spec handle_update(BinaryNode.t(), keyword()) ::
          {:ok, presence_update()} | :ignore | {:error, :invalid_presence_node}
  def handle_update(node, opts \\ [])

  def handle_update(%BinaryNode{tag: tag, attrs: attrs} = node, opts)
      when tag in ["presence", "chatstate"] do
    jid = attrs["from"]
    participant = attrs["participant"] || jid

    cond do
      not is_binary(jid) or jid == "" ->
        {:error, :invalid_presence_node}

      should_ignore_jid?(jid, opts) and jid != JID.s_whatsapp_net() ->
        :ignore

      true ->
        with {:ok, presence} <- parse_presence(node) do
          update = %{id: jid, presences: %{participant => presence}}
          emit_presence_update(opts, update)
          {:ok, update}
        end
    end
  end

  def handle_update(%BinaryNode{}, _opts), do: :ignore

  defp parse_presence(%BinaryNode{tag: "presence", attrs: attrs}) do
    {:ok,
     %{
       last_known_presence: if(attrs["type"] == "unavailable", do: :unavailable, else: :available)
     }
     |> maybe_put_last_seen(attrs["last"])}
  end

  defp parse_presence(%BinaryNode{tag: "chatstate", content: [%BinaryNode{} = child | _rest]}) do
    presence =
      child
      |> child_presence_type()
      |> then(&%{last_known_presence: &1})

    {:ok, presence}
  end

  defp parse_presence(%BinaryNode{tag: "chatstate"}), do: {:error, :invalid_presence_node}

  defp child_presence_type(%BinaryNode{tag: tag, attrs: attrs}) do
    if attrs["media"] == "audio" do
      :recording
    else
      case tag do
        "available" -> :available
        "unavailable" -> :unavailable
        "paused" -> :available
        "recording" -> :recording
        "composing" -> :composing
        _other -> :available
      end
    end
  end

  defp availability_node(name, type) do
    %BinaryNode{
      tag: "presence",
      attrs: %{"name" => String.replace(name, "@", ""), "type" => Atom.to_string(type)},
      content: nil
    }
  end

  defp chatstate_node(from_jid, to_jid, :recording) do
    %BinaryNode{
      tag: "chatstate",
      attrs: %{"from" => from_jid, "to" => to_jid},
      content: [%BinaryNode{tag: "composing", attrs: %{"media" => "audio"}, content: nil}]
    }
  end

  defp chatstate_node(from_jid, to_jid, type) do
    %BinaryNode{
      tag: "chatstate",
      attrs: %{"from" => from_jid, "to" => to_jid},
      content: [%BinaryNode{tag: Atom.to_string(type), attrs: %{}, content: nil}]
    }
  end

  defp chatstate_from_jid(to_jid, opts) do
    case JID.parse(to_jid) do
      %BaileysEx.JID{server: "lid"} ->
        required_from_jid(opts[:me_lid])

      %BaileysEx.JID{} ->
        required_from_jid(opts[:me_id])

      nil ->
        {:error, :invalid_to_jid}
    end
  end

  defp required_from_jid(from_jid) when is_binary(from_jid) and from_jid != "",
    do: {:ok, from_jid}

  defp required_from_jid(_from_jid), do: {:error, :missing_from_jid}

  defp maybe_put_last_seen(presence, nil), do: presence
  defp maybe_put_last_seen(presence, "deny"), do: presence

  defp maybe_put_last_seen(presence, value) do
    case Integer.parse(value) do
      {last_seen, ""} -> Map.put(presence, :last_seen, last_seen)
      _ -> presence
    end
  end

  defp should_ignore_jid?(jid, opts) do
    case opts[:should_ignore_jid_fun] do
      fun when is_function(fun, 1) -> !!fun.(jid)
      _ -> false
    end
  end

  defp emit_presence_update(opts, update) do
    case opts[:emit_fun] do
      fun when is_function(fun, 1) ->
        fun.(update)

      _ ->
        case opts[:event_emitter] do
          nil -> :ok
          event_emitter -> EventEmitter.emit(event_emitter, :presence_update, update)
        end
    end
  end

  defp message_tag(opts) do
    case opts[:message_tag_fun] do
      fun when is_function(fun, 0) -> fun.()
      _ -> Integer.to_string(System.unique_integer([:positive, :monotonic]))
    end
  end

  defp send_presence_update({module, server}, type) when is_atom(module),
    do: module.send_presence_update(server, type)

  defp send_presence_update(server, type) when type in [:available, :unavailable],
    do: Socket.send_presence_update(server, type)
end
