defmodule BaileysEx.Signal.PreKeyTest do
  use ExUnit.Case, async: true

  alias BaileysEx.Auth.State
  alias BaileysEx.BinaryNode
  alias BaileysEx.Protocol.BinaryNode, as: BinaryNodeUtil
  alias BaileysEx.Signal.PreKey
  alias BaileysEx.Signal.Store

  setup do
    {:ok, store} = Store.start_link()
    %{store: store}
  end

  test "next_pre_keys_node/3 generates upload keys, persists them, and builds the encrypt IQ", %{
    store: store
  } do
    state = State.new()

    assert {:ok, %{update: update, node: node}} = PreKey.next_pre_keys_node(store, state, 3)

    assert update == %{next_pre_key_id: 4, first_unuploaded_pre_key_id: 4}

    assert %BinaryNode{
             tag: "iq",
             attrs: %{"xmlns" => "encrypt", "type" => "set", "to" => "s.whatsapp.net"},
             content: content
           } = node

    assert %BinaryNode{tag: "registration"} = Enum.find(content, &(&1.tag == "registration"))
    assert %BinaryNode{tag: "type"} = Enum.find(content, &(&1.tag == "type"))

    assert %BinaryNode{tag: "identity", content: identity_public} =
             Enum.find(content, &(&1.tag == "identity"))

    assert identity_public == state.signed_identity_key.public

    assert %BinaryNode{tag: "list"} = list_node = Enum.find(content, &(&1.tag == "list"))
    assert length(BinaryNodeUtil.children(list_node, "key")) == 3
    assert %BinaryNode{tag: "skey"} = Enum.find(content, &(&1.tag == "skey"))

    assert Map.keys(Store.get(store, :"pre-key", ["1", "2", "3"])) == ["1", "2", "3"]
  end

  test "upload_if_required/1 uploads a fresh bundle when the server count is low", %{store: store} do
    parent = self()
    state = State.new() |> Map.put(:me, %{id: "15551234567@s.whatsapp.net"})

    query_fun = fn
      %BinaryNode{attrs: %{"xmlns" => "encrypt", "type" => "get"}} = node ->
        send(parent, {:prekey_count_query, node})

        {:ok,
         %BinaryNode{
           tag: "iq",
           attrs: %{"type" => "result"},
           content: [%BinaryNode{tag: "count", attrs: %{"value" => "0"}, content: nil}]
         }}

      %BinaryNode{attrs: %{"xmlns" => "encrypt", "type" => "set"}} = node ->
        send(parent, {:prekey_upload, node})
        {:ok, %BinaryNode{tag: "iq", attrs: %{"type" => "result"}, content: nil}}
    end

    assert :ok =
             PreKey.upload_if_required(
               store: store,
               auth_state: state,
               query_fun: query_fun,
               emit_creds_update: fn update ->
                 send(parent, {:creds_update, update})
                 :ok
               end,
               upload_key: {"test-upload", System.unique_integer([:positive])},
               initial_prekey_count: 3,
               min_prekey_count: 2,
               now_ms: fn -> 10_000 end,
               get_last_upload_at: fn -> nil end,
               put_last_upload_at: fn timestamp ->
                 send(parent, {:last_upload_at, timestamp})
                 :ok
               end
             )

    assert_receive {:prekey_count_query,
                    %BinaryNode{attrs: %{"xmlns" => "encrypt", "type" => "get"}}}

    assert_receive {:creds_update, %{next_pre_key_id: 4, first_unuploaded_pre_key_id: 4}}
    assert_receive {:prekey_upload, %BinaryNode{attrs: %{"xmlns" => "encrypt", "type" => "set"}}}
    assert_receive {:last_upload_at, 10_000}
    assert Map.keys(Store.get(store, :"pre-key", ["1", "2", "3"])) == ["1", "2", "3"]
  end
end
