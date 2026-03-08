defmodule BaileysExTest do
  use ExUnit.Case

  test "application starts supervision tree" do
    assert Process.whereis(BaileysEx.Supervisor) |> is_pid()
    assert Process.whereis(BaileysEx.Registry) |> is_pid()
    assert Process.whereis(BaileysEx.ConnectionSupervisor) |> is_pid()
    assert Process.whereis(BaileysEx.TaskSupervisor) |> is_pid()
  end

  test "JID struct" do
    jid = %BaileysEx.JID{user: "5511999887766", server: "s.whatsapp.net"}
    assert jid.user == "5511999887766"
    assert jid.server == "s.whatsapp.net"
    assert jid.device == nil
  end

  test "BinaryNode struct" do
    node = %BaileysEx.BinaryNode{
      tag: "message",
      attrs: %{"to" => "123@s.whatsapp.net"},
      content: [%BaileysEx.BinaryNode{tag: "body", content: "hello"}]
    }

    assert node.tag == "message"
    assert node.attrs["to"] == "123@s.whatsapp.net"
    assert [child] = node.content
    assert child.tag == "body"
    assert child.content == "hello"
  end
end
