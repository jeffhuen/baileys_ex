defmodule BaileysEx.Message.PeerDataTest do
  use ExUnit.Case, async: true

  alias BaileysEx.BinaryNode
  alias BaileysEx.JID
  alias BaileysEx.Message.PeerData
  alias BaileysEx.Message.Wire
  alias BaileysEx.Protocol.JID, as: JIDUtil
  alias BaileysEx.Protocol.Proto.Message
  alias BaileysEx.Signal.Repository
  alias BaileysEx.Signal.Store
  alias BaileysEx.TestHelpers.MessageSignalHelpers

  test "send_request/3 relays a peer protocol message to self with category and meta appdata" do
    parent = self()
    {repo, store} = MessageSignalHelpers.new_repo()
    session = MessageSignalHelpers.session_fixture()

    repo =
      repo
      |> inject_session!("15550001111:2@s.whatsapp.net", session)

    assert :ok = Store.set(store, %{:"device-list" => %{"15550001111" => ["2"]}})

    context = %{
      signal_repository: repo,
      signal_store: store,
      me_id: "15550001111:1@s.whatsapp.net",
      send_node_fun: fn node ->
        send(parent, {:relay_node, node})
        :ok
      end
    }

    request = %Message.PeerDataOperationRequestMessage{
      peer_data_operation_request_type: :PLACEHOLDER_MESSAGE_RESEND,
      placeholder_message_resend_request: [
        %Message.PeerDataOperationRequestMessage.PlaceholderMessageResendRequest{
          message_key: %BaileysEx.Protocol.Proto.MessageKey{
            remote_jid: "15551234567@s.whatsapp.net",
            id: "msg-1",
            from_me: false
          }
        }
      ]
    }

    assert {:ok, request_id, %{signal_repository: updated_repo}} =
             PeerData.send_request(context, request,
               message_id_fun: fn _me_id -> "3EB0PEERDATAID" end
             )

    assert request_id == "3EB0PEERDATAID"

    assert_receive {:relay_node,
                    %BinaryNode{
                      tag: "message",
                      attrs: %{
                        "to" => "15550001111@s.whatsapp.net",
                        "id" => "3EB0PEERDATAID",
                        "category" => "peer",
                        "push_priority" => "high_force",
                        "type" => "protocol"
                      },
                      content: content
                    }}

    assert %BinaryNode{tag: "meta", attrs: %{"appdata" => "default"}} =
             Enum.find(content, &match?(%BinaryNode{tag: "meta"}, &1))

    assert %{"15550001111.2" => %{history: history}} = updated_repo.adapter_state

    assert Enum.any?(history, fn
             {:encrypted, payload} ->
               match?(
                 {:ok,
                  %Message{
                    device_sent_message: %Message.DeviceSentMessage{
                      destination_jid: "15550001111@s.whatsapp.net",
                      message: %Message{
                        protocol_message: %Message.ProtocolMessage{
                          type: :PEER_DATA_OPERATION_REQUEST_MESSAGE,
                          peer_data_operation_request_message:
                            %Message.PeerDataOperationRequestMessage{
                              peer_data_operation_request_type: :PLACEHOLDER_MESSAGE_RESEND
                            }
                        }
                      }
                    }
                  }},
                 Wire.decode(payload)
               )

             _ ->
               false
           end)
  end

  test "fetch_message_history/5 builds the on-demand history request payload" do
    {repo, store} = MessageSignalHelpers.new_repo()
    session = MessageSignalHelpers.session_fixture()

    repo =
      repo
      |> inject_session!("15550001111:2@s.whatsapp.net", session)

    assert :ok = Store.set(store, %{:"device-list" => %{"15550001111" => ["2"]}})

    context = %{
      signal_repository: repo,
      signal_store: store,
      me_id: "15550001111:1@s.whatsapp.net",
      send_node_fun: fn _node -> :ok end
    }

    oldest_key = %{
      remote_jid: JIDUtil.to_string(%JID{user: "15551234567", server: "s.whatsapp.net"}),
      from_me: false,
      id: "oldest-1"
    }

    assert {:ok, "3EB0HISTORYID", %{signal_repository: updated_repo}} =
             PeerData.fetch_message_history(context, 25, oldest_key, 1_710_000_700_000,
               message_id_fun: fn _me_id -> "3EB0HISTORYID" end
             )

    assert %{"15550001111.2" => %{history: history}} = updated_repo.adapter_state

    assert Enum.any?(history, fn
             {:encrypted, payload} ->
               match?(
                 {:ok,
                  %Message{
                    device_sent_message: %Message.DeviceSentMessage{
                      destination_jid: "15550001111@s.whatsapp.net",
                      message: %Message{
                        protocol_message: %Message.ProtocolMessage{
                          peer_data_operation_request_message:
                            %Message.PeerDataOperationRequestMessage{
                              peer_data_operation_request_type: :HISTORY_SYNC_ON_DEMAND,
                              history_sync_on_demand_request:
                                %Message.PeerDataOperationRequestMessage.HistorySyncOnDemandRequest{
                                  chat_jid: "15551234567@s.whatsapp.net",
                                  oldest_msg_id: "oldest-1",
                                  oldest_msg_from_me: false,
                                  on_demand_msg_count: 25,
                                  oldest_msg_timestamp_ms: 1_710_000_700_000
                                }
                            }
                        }
                      }
                    }
                  }},
                 Wire.decode(payload)
               )

             _ ->
               false
           end)
  end

  defp inject_session!(repo, jid, session) do
    assert {:ok, next_repo} = Repository.inject_e2e_session(repo, %{jid: jid, session: session})
    next_repo
  end
end
