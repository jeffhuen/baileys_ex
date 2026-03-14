defmodule BaileysEx.Message.IntegrationTest do
  use ExUnit.Case, async: true

  alias BaileysEx.BinaryNode
  alias BaileysEx.Connection.EventEmitter
  alias BaileysEx.Message.Receiver
  alias BaileysEx.Message.Sender
  alias BaileysEx.Protocol.Proto.Message
  alias BaileysEx.Signal.Repository
  alias BaileysEx.Signal.Store

  defmodule E2EAdapter do
    @behaviour Repository.Adapter

    @impl true
    def inject_e2e_session(state, address, session) do
      key = Repository.Adapter.session_key(address)
      {:ok, Map.put(state, key, %{open?: true, session: session})}
    end

    @impl true
    def validate_session(state, address) do
      case Map.get(state, Repository.Adapter.session_key(address)) do
        %{open?: true} -> {:ok, :exists}
        %{open?: false} -> {:ok, :no_open_session}
        nil -> {:ok, :no_session}
      end
    end

    @impl true
    def encrypt_message(state, address, plaintext) do
      key = Repository.Adapter.session_key(address)

      case Map.get(state, key) do
        %{open?: true, session: session} ->
          ciphertext = session_tag(session) <> "|" <> plaintext
          {:ok, state, %{type: :pkmsg, ciphertext: ciphertext}}

        _ ->
          {:error, :no_session}
      end
    end

    @impl true
    def decrypt_message(state, address, _type, ciphertext) do
      key = Repository.Adapter.session_key(address)

      case Map.get(state, key) do
        %{open?: true, session: session} ->
          tag = session_tag(session)

          case ciphertext do
            <<^tag::binary-size(16), "|", plaintext::binary>> -> {:ok, state, plaintext}
            _ -> {:error, :invalid_ciphertext}
          end

        _ ->
          {:error, :no_session}
      end
    end

    @impl true
    def delete_sessions(state, addresses) do
      {:ok, Enum.reduce(addresses, state, &Map.delete(&2, Repository.Adapter.session_key(&1)))}
    end

    @impl true
    def migrate_sessions(state, operations) do
      {next_state, migrated} =
        Enum.reduce(operations, {state, 0}, fn operation, {acc, count} ->
          from_key = Repository.Adapter.session_key(operation.from)
          to_key = Repository.Adapter.session_key(operation.to)

          case Map.pop(acc, from_key) do
            {nil, unchanged} -> {unchanged, count}
            {session, rest} -> {Map.put(rest, to_key, session), count + 1}
          end
        end)

      {:ok, next_state, %{migrated: migrated, skipped: 0, total: length(operations)}}
    end

    @impl true
    def encrypt_group_message(_state, _sender_key_name, _plaintext), do: {:error, :unsupported}

    @impl true
    def process_sender_key_distribution_message(_state, _sender_key_name, _distribution_message),
      do: {:error, :unsupported}

    @impl true
    def decrypt_group_message(_state, _sender_key_name, _ciphertext), do: {:error, :unsupported}

    defp session_tag(session) do
      session
      |> :erlang.term_to_binary()
      |> then(&:crypto.hash(:sha256, &1))
      |> binary_part(0, 16)
    end
  end

  test "text messages roundtrip from sender relay construction through receiver decryption" do
    {:ok, emitter} = EventEmitter.start_link()
    parent = self()
    unsubscribe = EventEmitter.process(emitter, &send(parent, {:events, &1}))

    {:ok, store} = Store.start_link()

    session = %{
      registration_id: 42,
      identity_key: <<21::256>>,
      signed_pre_key: %{
        key_id: 7,
        public_key: <<22::256>>,
        signature: :binary.copy(<<23>>, 64)
      },
      pre_key: %{key_id: 8, public_key: <<24::256>>}
    }

    sender_repo =
      Repository.new(adapter: E2EAdapter, store: store)
      |> inject_session!("15551234567:0@s.whatsapp.net", session)

    receiver_repo =
      Repository.new(adapter: E2EAdapter, store: store)
      |> inject_session!("15550001111:1@s.whatsapp.net", session)

    assert :ok =
             Store.set(store, %{:"device-list" => %{"15551234567" => ["0"], "15550001111" => []}})

    sender_context = %{
      signal_repository: sender_repo,
      signal_store: store,
      me_id: "15550001111:1@s.whatsapp.net",
      send_node_fun: fn node ->
        send(parent, {:relay_node, node})
        :ok
      end
    }

    jid = %BaileysEx.JID{user: "15551234567", server: "s.whatsapp.net"}

    assert {:ok, %{id: "3EB0ROUNDTRIP"}, _context} =
             Sender.send(sender_context, jid, %{text: "roundtrip"},
               message_id_fun: fn _me_id -> "3EB0ROUNDTRIP" end
             )

    assert_receive {:relay_node, %BinaryNode{content: content}}

    participants = Enum.find(content, &match?(%BinaryNode{tag: "participants"}, &1)).content

    ciphertext =
      Enum.find_value(participants, fn
        %BinaryNode{
          tag: "to",
          attrs: %{"jid" => "15551234567:0@s.whatsapp.net"},
          content: [%BinaryNode{tag: "enc", content: {:binary, value}}]
        } ->
          value

        _ ->
          nil
      end)

    inbound = %BinaryNode{
      tag: "message",
      attrs: %{
        "id" => "3EB0ROUNDTRIP",
        "from" => "15550001111:1@s.whatsapp.net",
        "t" => "1710000900"
      },
      content: [
        %BinaryNode{tag: "enc", attrs: %{"type" => "pkmsg"}, content: {:binary, ciphertext}}
      ]
    }

    receiver_context = %{
      signal_repository: receiver_repo,
      event_emitter: emitter,
      me_id: "15551234567@s.whatsapp.net",
      me_lid: "15551234567@lid"
    }

    assert {:ok,
            %{
              message: %Message{
                extended_text_message: %Message.ExtendedTextMessage{text: "roundtrip"}
              }
            }, _context} = Receiver.process_node(inbound, receiver_context)

    assert_receive {:events,
                    %{
                      messages_upsert: %{
                        messages: [
                          %{
                            message: %Message{
                              extended_text_message: %Message.ExtendedTextMessage{
                                text: "roundtrip"
                              }
                            }
                          }
                        ]
                      }
                    }}

    unsubscribe.()
  end

  test "reaction messages roundtrip from sender relay construction through receiver side effects" do
    {:ok, emitter} = EventEmitter.start_link()
    parent = self()
    unsubscribe = EventEmitter.process(emitter, &send(parent, {:events, &1}))

    {:ok, store} = Store.start_link()

    session = %{
      registration_id: 42,
      identity_key: <<25::256>>,
      signed_pre_key: %{
        key_id: 7,
        public_key: <<26::256>>,
        signature: :binary.copy(<<27>>, 64)
      },
      pre_key: %{key_id: 8, public_key: <<28::256>>}
    }

    sender_repo =
      Repository.new(adapter: E2EAdapter, store: store)
      |> inject_session!("15551234567:0@s.whatsapp.net", session)

    receiver_repo =
      Repository.new(adapter: E2EAdapter, store: store)
      |> inject_session!("15550001111:1@s.whatsapp.net", session)

    assert :ok =
             Store.set(store, %{:"device-list" => %{"15551234567" => ["0"], "15550001111" => []}})

    sender_context = %{
      signal_repository: sender_repo,
      signal_store: store,
      me_id: "15550001111:1@s.whatsapp.net",
      send_node_fun: fn node ->
        send(parent, {:relay_node, node})
        :ok
      end
    }

    jid = %BaileysEx.JID{user: "15551234567", server: "s.whatsapp.net"}

    assert {:ok, %{id: "3EB0REACTION"}, _context} =
             Sender.send(
               sender_context,
               jid,
               %{
                 react: %{
                   key: %{id: "source-msg-1", remote_jid: jid},
                   text: "🔥"
                 }
               },
               message_id_fun: fn _me_id -> "3EB0REACTION" end
             )

    assert_receive {:relay_node, %BinaryNode{content: content}}

    participants = Enum.find(content, &match?(%BinaryNode{tag: "participants"}, &1)).content

    ciphertext =
      Enum.find_value(participants, fn
        %BinaryNode{
          tag: "to",
          attrs: %{"jid" => "15551234567:0@s.whatsapp.net"},
          content: [%BinaryNode{tag: "enc", content: {:binary, value}}]
        } ->
          value

        _ ->
          nil
      end)

    inbound = %BinaryNode{
      tag: "message",
      attrs: %{
        "id" => "3EB0REACTION",
        "from" => "15550001111:1@s.whatsapp.net",
        "t" => "1710000901"
      },
      content: [
        %BinaryNode{tag: "enc", attrs: %{"type" => "pkmsg"}, content: {:binary, ciphertext}}
      ]
    }

    receiver_context = %{
      signal_repository: receiver_repo,
      event_emitter: emitter,
      me_id: "15551234567@s.whatsapp.net",
      me_lid: "15551234567@lid"
    }

    assert {:ok, %{message: %Message{reaction_message: %Message.ReactionMessage{text: "🔥"}}},
            _context} = Receiver.process_node(inbound, receiver_context)

    assert_receive {:events,
                    %{
                      messages_reaction: [
                        %{
                          key: %{
                            id: "source-msg-1",
                            remote_jid: "15550001111@s.whatsapp.net",
                            from_me: true
                          },
                          reaction: %{text: "🔥", key: %{id: "3EB0REACTION"}}
                        }
                      ]
                    }}

    unsubscribe.()
  end

  defp inject_session!(repo, jid, session) do
    assert {:ok, next_repo} = Repository.inject_e2e_session(repo, %{jid: jid, session: session})
    next_repo
  end
end
