defmodule BaileysEx.Parity.ProtocolTest do
  use BaileysEx.Parity.Case, async: true

  alias BaileysEx.BinaryNode
  alias BaileysEx.Protocol.BinaryNode, as: BinaryNodeCodec
  alias BaileysEx.Protocol.JID, as: JIDUtil

  test "Baileys WABinary encode matches Elixir for a simple iq node" do
    node = %BinaryNode{
      tag: "iq",
      attrs: %{"type" => "get", "xmlns" => "urn:xmpp:ping"}
    }

    expected_hex =
      run_baileys_reference!("wabinary.encode", %{
        "node" => %{
          "tag" => node.tag,
          "attrs" => node.attrs,
          "content" => nil
        }
      })["encoded_hex"]

    actual_hex =
      node
      |> BinaryNodeCodec.encode()
      |> Base.encode16(case: :lower)

    assert actual_hex == expected_hex
  end

  test "Baileys WABinary decode matches Elixir for a simple iq node" do
    encoded_hex = "00F805190429162B"

    expected_node =
      run_baileys_reference!("wabinary.decode", %{
        "encoded_hex" => encoded_hex
      })["node"]

    actual_node =
      encoded_hex
      |> Base.decode16!(case: :mixed)
      |> BinaryNodeCodec.decode()
      |> then(fn {:ok, node} -> normalize_binary_node(node) end)

    assert actual_node == expected_node
  end

  test "Baileys jidDecode matches Elixir parse for agent and device JIDs" do
    jid = "15551234567_8:3@s.whatsapp.net"

    expected =
      run_baileys_reference!("jid.decode", %{
        "jid" => jid
      })["jid"]

    actual =
      jid
      |> JIDUtil.parse()
      |> normalize_jid()

    assert actual == expected
  end

  test "Baileys jidNormalizedUser matches Elixir normalized_user for c.us inputs" do
    jid = "15551234567:9@c.us"

    expected =
      run_baileys_reference!("jid.normalized_user", %{
        "jid" => jid
      })["jid"]

    assert JIDUtil.normalized_user(jid) == expected
  end

  test "Baileys areJidsSameUser matches Elixir same_user? across device and server variants" do
    jid1 = "15551234567:2@s.whatsapp.net"
    jid2 = "15551234567@lid"

    expected =
      run_baileys_reference!("jid.same_user", %{
        "jid1" => jid1,
        "jid2" => jid2
      })["same_user"]

    assert JIDUtil.same_user?(jid1, jid2) == expected
  end

  test "Baileys jidEncode matches Elixir jid_encode for user, agent, and device components" do
    input = %{
      "user" => "15551234567",
      "server" => "s.whatsapp.net",
      "device" => 3,
      "agent" => 8
    }

    expected =
      run_baileys_reference!("jid.encode", input)["jid"]

    assert JIDUtil.jid_encode("15551234567", "s.whatsapp.net", 3, 8) == expected
  end

  defp normalize_jid(nil), do: nil

  defp normalize_jid(%BaileysEx.JID{user: user, server: server, device: device, agent: agent}) do
    %{
      "user" => user,
      "server" => server,
      "device" => device,
      "agent" => agent
    }
  end
end
