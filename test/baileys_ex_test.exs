defmodule BaileysExTest do
  use ExUnit.Case

  alias BaileysEx.Auth.FilePersistence
  alias BaileysEx.Auth.NativeFilePersistence
  alias BaileysEx.Auth.State

  test "library application does not auto-start runtime supervision tree" do
    application = BaileysEx.MixProject.application()

    refute Keyword.has_key?(application, :mod)
    assert Keyword.get(application, :extra_applications) == [:logger, :crypto]
  end

  @tag :tmp_dir
  test "file persistence convenience defaults ignore application environment", %{tmp_dir: tmp_dir} do
    native_env_path = Path.join(tmp_dir, "env-native")
    json_env_path = Path.join(tmp_dir, "env-json")

    Application.put_env(:baileys_ex, NativeFilePersistence, path: native_env_path)
    Application.put_env(:baileys_ex, FilePersistence, path: json_env_path)

    on_exit(fn ->
      Application.delete_env(:baileys_ex, NativeFilePersistence)
      Application.delete_env(:baileys_ex, FilePersistence)
    end)

    File.cd!(tmp_dir, fn ->
      assert {:ok, %State{}} = NativeFilePersistence.load_credentials()
      assert File.dir?(Path.join(tmp_dir, "baileys_native_auth_info"))
      refute File.exists?(native_env_path)

      assert {:ok, %State{}} = FilePersistence.load_credentials()
      assert File.dir?(Path.join(tmp_dir, "baileys_auth_info"))
      refute File.exists?(json_env_path)
    end)
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
