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

    assert %BinaryNode{tag: "identity", content: {:binary, identity_public}} =
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

  test "digest_key_bundle/1 sends encrypt digest and succeeds when the digest node is present", %{
    store: store
  } do
    parent = self()
    state = State.new() |> Map.put(:me, %{id: "15551234567@s.whatsapp.net"})

    assert :ok =
             PreKey.digest_key_bundle(
               store: store,
               auth_state: state,
               query_fun: fn
                 %BinaryNode{
                   attrs: %{"xmlns" => "encrypt", "type" => "get"},
                   content: [%BinaryNode{tag: "digest"}]
                 } = node ->
                   send(parent, {:digest_query, node})

                   {:ok,
                    %BinaryNode{
                      tag: "iq",
                      attrs: %{"type" => "result"},
                      content: [%BinaryNode{tag: "digest", attrs: %{}, content: nil}]
                    }}
               end
             )

    assert_receive {:digest_query,
                    %BinaryNode{
                      attrs: %{"xmlns" => "encrypt", "type" => "get"},
                      content: [%BinaryNode{tag: "digest"}]
                    }}
  end

  test "digest_key_bundle/1 uploads pre-keys when the server digest response is missing", %{
    store: store
  } do
    parent = self()
    state = State.new() |> Map.put(:me, %{id: "15551234567@s.whatsapp.net"})

    assert {:error, :missing_digest_node} =
             PreKey.digest_key_bundle(
               store: store,
               auth_state: state,
               query_fun: fn
                 %BinaryNode{
                   attrs: %{"xmlns" => "encrypt", "type" => "get"},
                   content: [%BinaryNode{tag: "digest"}] = _content
                 } = node ->
                   send(parent, {:digest_query, node})
                   {:ok, %BinaryNode{tag: "iq", attrs: %{"type" => "result"}, content: nil}}

                 %BinaryNode{
                   attrs: %{"xmlns" => "encrypt", "type" => "get"},
                   content: [%BinaryNode{tag: "count"}]
                 } = node ->
                   send(parent, {:count_query, node})

                   {:ok,
                    %BinaryNode{
                      tag: "iq",
                      attrs: %{"type" => "result"},
                      content: [%BinaryNode{tag: "count", attrs: %{"value" => "0"}, content: nil}]
                    }}

                 %BinaryNode{attrs: %{"xmlns" => "encrypt", "type" => "set"}} = node ->
                   send(parent, {:upload_query, node})
                   {:ok, %BinaryNode{tag: "iq", attrs: %{"type" => "result"}, content: nil}}
               end,
               emit_creds_update: fn update ->
                 send(parent, {:creds_update, update})
                 :ok
               end,
               upload_key: {"digest-upload", System.unique_integer([:positive])},
               initial_prekey_count: 2,
               min_prekey_count: 2,
               now_ms: fn -> 10_000 end,
               get_last_upload_at: fn -> nil end,
               put_last_upload_at: fn _timestamp -> :ok end
             )

    assert_receive {:digest_query, %BinaryNode{}}
    assert_receive {:count_query, %BinaryNode{}}
    assert_receive {:creds_update, %{next_pre_key_id: 3, first_unuploaded_pre_key_id: 3}}
    assert_receive {:upload_query, %BinaryNode{attrs: %{"xmlns" => "encrypt", "type" => "set"}}}
  end

  test "rotate_signed_pre_key/1 uploads a rotated signed pre-key and emits creds updates" do
    parent = self()
    state = State.new()

    assert {:ok, %{signed_pre_key: signed_pre_key}} =
             PreKey.rotate_signed_pre_key(
               auth_state: state,
               query_fun: fn
                 %BinaryNode{
                   attrs: %{"xmlns" => "encrypt", "type" => "set"},
                   content: [%BinaryNode{tag: "rotate"} = rotate_node]
                 } = node ->
                   send(parent, {:rotate_query, node, rotate_node})
                   {:ok, %BinaryNode{tag: "iq", attrs: %{"type" => "result"}, content: nil}}
               end,
               emit_creds_update: fn update ->
                 send(parent, {:creds_update, update})
                 :ok
               end
             )

    assert signed_pre_key.key_id == state.signed_pre_key.key_id + 1
    assert_receive {:creds_update, %{signed_pre_key: ^signed_pre_key}}
    assert_receive {:rotate_query, %BinaryNode{}, %BinaryNode{tag: "rotate"}}
  end

  test "upload_if_required/1 returns an upload timeout when the upload exceeds the explicit timeout",
       %{
         store: store
       } do
    state = State.new() |> Map.put(:me, %{id: "15551234567@s.whatsapp.net"})

    assert {:error, :upload_timeout} =
             PreKey.upload_if_required(
               store: store,
               auth_state: state,
               query_fun: fn
                 %BinaryNode{
                   attrs: %{"xmlns" => "encrypt", "type" => "get"},
                   content: [%BinaryNode{tag: "count"}]
                 } ->
                   {:ok,
                    %BinaryNode{
                      tag: "iq",
                      attrs: %{"type" => "result"},
                      content: [%BinaryNode{tag: "count", attrs: %{"value" => "0"}, content: nil}]
                    }}

                 %BinaryNode{attrs: %{"xmlns" => "encrypt", "type" => "set"}} ->
                   Process.sleep(30)
                   {:ok, %BinaryNode{tag: "iq", attrs: %{"type" => "result"}, content: nil}}
               end,
               emit_creds_update: fn _update -> :ok end,
               upload_key: {"timed-upload", System.unique_integer([:positive])},
               initial_prekey_count: 2,
               min_prekey_count: 2,
               upload_timeout_ms: 5
             )
  end
end
