defmodule BaileysEx.Protocol.BinaryNodeTest do
  use ExUnit.Case, async: true

  alias BaileysEx.BinaryNode
  alias BaileysEx.Protocol.BinaryNode, as: BinaryNodeCodec

  describe "encode/1 and decode/1 roundtrip" do
    test "simple node with tag only" do
      node = %BinaryNode{tag: "iq", attrs: %{}}
      encoded = BinaryNodeCodec.encode(node)
      assert {:ok, decoded} = BinaryNodeCodec.decode(encoded)
      assert decoded.tag == "iq"
      assert decoded.attrs == %{}
      assert decoded.content == nil
    end

    test "node with dictionary token attributes" do
      node = %BinaryNode{
        tag: "iq",
        attrs: %{"type" => "get", "xmlns" => "urn:xmpp:ping"}
      }

      encoded = BinaryNodeCodec.encode(node)
      assert {:ok, decoded} = BinaryNodeCodec.decode(encoded)
      assert decoded.tag == "iq"
      assert decoded.attrs["type"] == "get"
      assert decoded.attrs["xmlns"] == "urn:xmpp:ping"
    end

    test "node with binary content" do
      binary_content = <<1, 2, 3, 4, 5, 0, 255>>

      node = %BinaryNode{
        tag: "enc",
        attrs: %{"type" => "msg"},
        content: {:binary, binary_content}
      }

      encoded = BinaryNodeCodec.encode(node)
      assert {:ok, decoded} = BinaryNodeCodec.decode(encoded)
      assert decoded.tag == "enc"
      assert decoded.attrs["type"] == "msg"
      assert decoded.content == {:binary, binary_content}
    end

    test "node with child nodes" do
      node = %BinaryNode{
        tag: "iq",
        attrs: %{"type" => "get"},
        content: [
          %BinaryNode{tag: "query", attrs: %{}},
          %BinaryNode{tag: "list", attrs: %{"type" => "result"}}
        ]
      }

      encoded = BinaryNodeCodec.encode(node)
      assert {:ok, decoded} = BinaryNodeCodec.decode(encoded)
      assert decoded.tag == "iq"
      assert length(decoded.content) == 2
      [child1, child2] = decoded.content
      assert child1.tag == "query"
      assert child2.tag == "list"
      assert child2.attrs["type"] == "result"
    end

    test "deeply nested nodes" do
      node = %BinaryNode{
        tag: "iq",
        attrs: %{},
        content: [
          %BinaryNode{
            tag: "query",
            attrs: %{},
            content: [
              %BinaryNode{tag: "item", attrs: %{"name" => "test"}}
            ]
          }
        ]
      }

      encoded = BinaryNodeCodec.encode(node)
      assert {:ok, decoded} = BinaryNodeCodec.decode(encoded)
      assert decoded.tag == "iq"
      [query] = decoded.content
      assert query.tag == "query"
      [item] = query.content
      assert item.tag == "item"
      assert item.attrs["name"] == "test"
    end

    test "node with JID attribute value" do
      node = %BinaryNode{
        tag: "message",
        attrs: %{
          "to" => "5511999887766@s.whatsapp.net",
          "from" => "120363001234567890@g.us"
        }
      }

      encoded = BinaryNodeCodec.encode(node)
      assert {:ok, decoded} = BinaryNodeCodec.decode(encoded)
      assert decoded.tag == "message"
      assert decoded.attrs["to"] == "5511999887766@s.whatsapp.net"
      assert decoded.attrs["from"] == "120363001234567890@g.us"
    end

    test "node with nibble-encoded attribute" do
      # A phone number like string: digits, dots, dashes
      node = %BinaryNode{
        tag: "iq",
        attrs: %{"id" => "123-456.789"}
      }

      encoded = BinaryNodeCodec.encode(node)
      assert {:ok, decoded} = BinaryNodeCodec.decode(encoded)
      assert decoded.attrs["id"] == "123-456.789"
    end

    test "node with hex-encoded attribute" do
      # Hex-only string
      node = %BinaryNode{
        tag: "iq",
        attrs: %{"id" => "DEADBEEF"}
      }

      encoded = BinaryNodeCodec.encode(node)
      assert {:ok, decoded} = BinaryNodeCodec.decode(encoded)
      assert decoded.attrs["id"] == "DEADBEEF"
    end

    test "node with raw string attribute (non-token, non-nibble, non-hex)" do
      node = %BinaryNode{
        tag: "message",
        attrs: %{"id" => "some_random_custom_id_value_xyz"}
      }

      encoded = BinaryNodeCodec.encode(node)
      assert {:ok, decoded} = BinaryNodeCodec.decode(encoded)
      assert decoded.attrs["id"] == "some_random_custom_id_value_xyz"
    end

    test "node with double-byte dictionary token" do
      # "read-self" is in double byte dict 0, index 0
      node = %BinaryNode{
        tag: "receipt",
        attrs: %{"type" => "read-self"}
      }

      encoded = BinaryNodeCodec.encode(node)
      assert {:ok, decoded} = BinaryNodeCodec.decode(encoded)
      assert decoded.attrs["type"] == "read-self"
    end

    test "node with empty attributes map" do
      node = %BinaryNode{tag: "presence", attrs: %{}}
      encoded = BinaryNodeCodec.encode(node)
      assert {:ok, decoded} = BinaryNodeCodec.decode(encoded)
      assert decoded.tag == "presence"
      assert decoded.attrs == %{}
    end

    test "node with nil content" do
      node = %BinaryNode{tag: "ack", attrs: %{"id" => "12345"}, content: nil}
      encoded = BinaryNodeCodec.encode(node)
      assert {:ok, decoded} = BinaryNodeCodec.decode(encoded)
      assert decoded.tag == "ack"
      assert decoded.content == nil
    end

    test "node with string content (non-token string)" do
      # A free-form string that doesn't match any token, nibble, hex, or JID
      # encoding falls through to write_string_raw (BINARY_* on the wire).
      # The decoder treats BINARY_* in content position as raw binary data,
      # matching Baileys semantics where Buffer.isBuffer content is used.
      node = %BinaryNode{
        tag: "notification",
        attrs: %{},
        content: "hello world xyz custom content"
      }

      encoded = BinaryNodeCodec.encode(node)
      assert {:ok, decoded} = BinaryNodeCodec.decode(encoded)
      assert decoded.tag == "notification"
      # Non-token strings in content position are decoded as {:binary, ...}
      # because the wire format (BINARY_*) is indistinguishable from raw bytes
      assert decoded.content == {:binary, "hello world xyz custom content"}
    end

    test "node with multiple attributes preserves all" do
      node = %BinaryNode{
        tag: "iq",
        attrs: %{
          "type" => "set",
          "xmlns" => "w:profile:picture",
          "to" => "5511999887766@s.whatsapp.net"
        }
      }

      encoded = BinaryNodeCodec.encode(node)
      assert {:ok, decoded} = BinaryNodeCodec.decode(encoded)
      assert decoded.attrs["type"] == "set"
      assert decoded.attrs["xmlns"] == "w:profile:picture"
      assert decoded.attrs["to"] == "5511999887766@s.whatsapp.net"
    end
  end

  describe "encode/1 specific behaviors" do
    test "encode matches the pinned bytes for a simple iq query" do
      node = %BinaryNode{
        tag: "iq",
        attrs: %{"type" => "get", "xmlns" => "urn:xmpp:ping"}
      }

      assert Base.decode16!("00F805190429162B", case: :mixed) == BinaryNodeCodec.encode(node)
    end

    test "encode produces binary starting with 0 byte (no compression)" do
      node = %BinaryNode{tag: "iq", attrs: %{}}
      encoded = BinaryNodeCodec.encode(node)
      assert <<0, _rest::binary>> = encoded
    end

    test "encodes empty string content as raw" do
      node = %BinaryNode{tag: "iq", attrs: %{}, content: ""}
      encoded = BinaryNodeCodec.encode(node)
      assert {:ok, decoded} = BinaryNodeCodec.decode(encoded)
      # Empty string goes through write_string_raw → BINARY_8 on wire →
      # decoded as {:binary, ""} since BINARY_* in content = raw bytes
      assert decoded.content == {:binary, ""}
    end
  end

  describe "decode/1 error handling" do
    test "returns error for empty binary" do
      assert {:error, _} = BinaryNodeCodec.decode(<<>>)
    end

    test "returns error for truncated data" do
      assert {:error, _} = BinaryNodeCodec.decode(<<0, 248>>)
    end
  end

  describe "encoding strategies" do
    test "single-byte dictionary tokens use 1 byte" do
      # "iq" is at single-byte index 25
      # With tag-only node: list_start(1) + tag
      # LIST_8(248), size(1), token(25) = 3 bytes + leading 0
      node = %BinaryNode{tag: "iq", attrs: %{}}
      encoded = BinaryNodeCodec.encode(node)
      # 0 (compression flag) + LIST_8(248) + 1 (size) + 25 (iq token)
      assert encoded == <<0, 248, 1, 25>>
    end

    test "double-byte dictionary tokens use dict prefix + index" do
      # "read-self" is DICTIONARY_0 (236), index 0
      node = %BinaryNode{tag: "receipt", attrs: %{"type" => "read-self"}}
      encoded = BinaryNodeCodec.encode(node)
      assert {:ok, decoded} = BinaryNodeCodec.decode(encoded)
      assert decoded.attrs["type"] == "read-self"
      # Verify the double-byte encoding is present in the binary
      # The encoded form should contain 236 (DICTIONARY_0) followed by 0
      assert :binary.match(encoded, <<236, 0>>) != :nomatch
    end

    test "nibble packing for digit strings" do
      node = %BinaryNode{tag: "iq", attrs: %{"id" => "12345"}}
      encoded = BinaryNodeCodec.encode(node)
      assert {:ok, decoded} = BinaryNodeCodec.decode(encoded)
      assert decoded.attrs["id"] == "12345"
      # Nibble encoding: NIBBLE_8(255) + length byte + packed bytes
      # 5 chars -> 3 bytes (ceil(5/2)=3, odd flag set: 3|128=131)
      assert :binary.match(encoded, <<255, 131>>) != :nomatch
    end

    test "hex packing for uppercase hex strings" do
      node = %BinaryNode{tag: "iq", attrs: %{"id" => "AB"}}
      encoded = BinaryNodeCodec.encode(node)
      assert {:ok, decoded} = BinaryNodeCodec.decode(encoded)
      assert decoded.attrs["id"] == "AB"
      # Hex encoding: HEX_8(251) + length byte + packed bytes
      assert :binary.match(encoded, <<251>>) != :nomatch
    end
  end

  describe "helper functions" do
    test "children/1 and children/2 return child nodes" do
      node = %BinaryNode{
        tag: "iq",
        attrs: %{},
        content: [
          %BinaryNode{tag: "query", attrs: %{}},
          %BinaryNode{tag: "user", attrs: %{"jid" => "1@s.whatsapp.net"}},
          %BinaryNode{tag: "user", attrs: %{"jid" => "2@s.whatsapp.net"}}
        ]
      }

      assert [
               %BinaryNode{tag: "query"},
               %BinaryNode{tag: "user", attrs: %{"jid" => "1@s.whatsapp.net"}},
               %BinaryNode{tag: "user", attrs: %{"jid" => "2@s.whatsapp.net"}}
             ] = BinaryNodeCodec.children(node)

      assert [
               %BinaryNode{tag: "user", attrs: %{"jid" => "1@s.whatsapp.net"}},
               %BinaryNode{tag: "user", attrs: %{"jid" => "2@s.whatsapp.net"}}
             ] = BinaryNodeCodec.children(node, "user")

      assert %BinaryNode{tag: "query"} = BinaryNodeCodec.child(node, "query")
      assert nil == BinaryNodeCodec.child(node, "missing")
    end

    test "child_string/2 and child_bytes/2 normalize child content" do
      node = %BinaryNode{
        tag: "iq",
        attrs: %{},
        content: [
          %BinaryNode{tag: "body", attrs: %{}, content: "hello"},
          %BinaryNode{tag: "payload", attrs: %{}, content: {:binary, <<1, 2, 3>>}},
          %BinaryNode{tag: "status", attrs: %{}, content: {:binary, "busy"}}
        ]
      }

      assert "hello" == BinaryNodeCodec.child_string(node, "body")
      assert "busy" == BinaryNodeCodec.child_string(node, "status")
      assert <<1, 2, 3>> == BinaryNodeCodec.child_bytes(node, "payload")
      assert nil == BinaryNodeCodec.child_bytes(node, "body")
    end

    test "assert_error_free/1 returns structured error data" do
      node = %BinaryNode{
        tag: "user",
        attrs: %{"jid" => "1@s.whatsapp.net"},
        content: [
          %BinaryNode{
            tag: "error",
            attrs: %{"code" => "401", "text" => "not-authorized"},
            content: nil
          }
        ]
      }

      assert {:error, %{code: 401, text: "not-authorized", node: %BinaryNode{tag: "error"}}} =
               BinaryNodeCodec.assert_error_free(node)
    end
  end
end
