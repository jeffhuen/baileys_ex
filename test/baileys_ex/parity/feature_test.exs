defmodule BaileysEx.Parity.FeatureTest do
  use BaileysEx.Parity.Case, async: true

  alias BaileysEx.BinaryNode
  alias BaileysEx.Feature.Presence
  alias BaileysEx.Feature.Privacy
  alias BaileysEx.Signal.Store

  test "Baileys sendPresenceUpdate matches Elixir for recording chatstate" do
    parent = self()

    sendable = fn node ->
      send(parent, {:node, node})
      :ok
    end

    assert :ok =
             Presence.send_update(sendable, :recording, "15551234567@lid",
               me_id: "15550001111@s.whatsapp.net",
               me_lid: "15550001111@lid"
             )

    assert_receive {:node, node}

    expected =
      run_baileys_reference!("feature.presence_send", %{
        "type" => "recording",
        "to_jid" => "15551234567@lid",
        "me_id" => "15550001111@s.whatsapp.net",
        "me_lid" => "15550001111@lid",
        "me_name" => "Jeff@Bot"
      })

    assert normalize_binary_node(node) == expected["node"]
  end

  test "Baileys presenceSubscribe matches Elixir for tc-token subscriptions" do
    {:ok, store} = Store.start_link()

    assert :ok =
             Store.set(store, %{
               tctoken: %{"15551234567@s.whatsapp.net" => %{token: "tc-token"}}
             })

    parent = self()

    sendable = fn node ->
      send(parent, {:node, node})
      :ok
    end

    assert :ok =
             Presence.subscribe(sendable, "15551234567@s.whatsapp.net",
               signal_store: store,
               message_tag_fun: fn -> "presence-sub-1" end
             )

    assert_receive {:node, node}

    expected =
      run_baileys_reference!("feature.presence_subscribe", %{
        "to_jid" => "15551234567@s.whatsapp.net",
        "message_tag" => "presence-sub-1",
        "tc_token_base64" => Base.encode64("tc-token")
      })

    assert normalize_binary_node(node) == expected["node"]
  end

  test "Baileys handlePresenceUpdate semantics match Elixir parsed output" do
    node = %BinaryNode{
      tag: "chatstate",
      attrs: %{
        "from" => "120363001234567890@g.us",
        "participant" => "15557654321@s.whatsapp.net"
      },
      content: [
        %BinaryNode{
          tag: "composing",
          attrs: %{"media" => "audio"},
          content: nil
        }
      ]
    }

    expected =
      run_baileys_reference!("feature.presence_parse", %{
        "node" => normalize_binary_node(node)
      })["update"]

    assert {:ok, update} = Presence.handle_update(node)

    assert normalize_presence_update(update) == expected
  end

  test "Baileys privacyQuery node matches Elixir read-receipts updates" do
    parent = self()

    queryable = fn node, _timeout ->
      send(parent, {:node, node})
      {:ok, %BinaryNode{tag: "iq", attrs: %{}, content: nil}}
    end

    assert {:ok, %BinaryNode{}} = Privacy.update_read_receipts(queryable, :all)
    assert_receive {:node, node}

    expected =
      run_baileys_reference!("feature.privacy_query", %{
        "name" => "readreceipts",
        "value" => "all"
      })

    assert normalize_binary_node(node) == expected["node"]
  end

  defp normalize_presence_update(%{id: id, presences: presences}) do
    %{
      "id" => id,
      "presences" =>
        Map.new(presences, fn {participant, presence} ->
          {participant,
           %{
             "last_known_presence" => Atom.to_string(presence.last_known_presence),
             "last_seen" => Map.get(presence, :last_seen)
           }}
        end)
    }
  end
end
