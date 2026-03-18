defmodule BaileysEx.Media.RetryTest do
  use ExUnit.Case, async: true

  alias BaileysEx.BinaryNode
  alias BaileysEx.Connection.EventEmitter
  alias BaileysEx.Crypto
  alias BaileysEx.Media.Retry
  alias BaileysEx.Protocol.BinaryNode, as: BinaryNodeUtil
  alias BaileysEx.Protocol.Proto.MediaRetryNotification
  alias BaileysEx.Protocol.Proto.Message
  alias BaileysEx.Protocol.Proto.MessageKey
  alias BaileysEx.Protocol.Proto.ServerErrorReceipt
  alias BaileysEx.Protocol.Proto.WebMessageInfo

  test "request_reupload/4 sends a Baileys-style server-error receipt with encrypted retry data" do
    parent = self()

    key = %{
      id: "media-msg-1",
      remote_jid: "15551234567@s.whatsapp.net",
      from_me: false,
      participant: "15551234567:1@s.whatsapp.net"
    }

    media_key = :binary.copy(<<7>>, 32)
    iv = :binary.copy(<<3>>, 12)

    assert :ok =
             Retry.request_reupload(:socket, key, media_key,
               me_id: "15550001111:5@s.whatsapp.net",
               iv: iv,
               send_fun: fn socket, %BinaryNode{} = node ->
                 send(parent, {:retry_node, socket, node})
                 :ok
               end
             )

    assert_receive {:retry_node, :socket, %BinaryNode{} = node}
    assert node.tag == "receipt"

    assert node.attrs == %{
             "id" => "media-msg-1",
             "to" => "15550001111@s.whatsapp.net",
             "type" => "server-error"
           }

    assert %BinaryNode{attrs: %{"jid" => "15551234567@s.whatsapp.net", "from_me" => "false"}} =
             BinaryNodeUtil.child(node, "rmr")

    encrypt = BinaryNodeUtil.child(node, "encrypt")
    ciphertext = BinaryNodeUtil.child_bytes(encrypt, "enc_p")
    assert BinaryNodeUtil.child_bytes(encrypt, "enc_iv") == iv

    assert {:ok, retry_key} =
             Crypto.hkdf(media_key, "WhatsApp Media Retry Notification", 32)

    assert {:ok, plaintext} = Crypto.aes_gcm_decrypt(retry_key, iv, ciphertext, key.id)

    assert {:ok, %ServerErrorReceipt{stanza_id: "media-msg-1"}} =
             ServerErrorReceipt.decode(plaintext)
  end

  test "decrypt_media_update/3 decodes the encrypted media-update payload" do
    media_key = :binary.copy(<<5>>, 32)
    iv = :binary.copy(<<9>>, 12)

    notification = %MediaRetryNotification{
      stanza_id: "media-msg-2",
      direct_path: "/mms/image/new-path",
      result: :SUCCESS,
      message_secret: <<1, 2, 3, 4>>
    }

    assert {:ok, retry_key} =
             Crypto.hkdf(media_key, "WhatsApp Media Retry Notification", 32)

    ciphertext =
      notification
      |> MediaRetryNotification.encode()
      |> then(fn payload ->
        {:ok, ciphertext} = Crypto.aes_gcm_encrypt(retry_key, iv, payload, "media-msg-2")
        ciphertext
      end)

    assert {:ok, %MediaRetryNotification{} = decoded} =
             Retry.decrypt_media_update(
               %{ciphertext: ciphertext, iv: iv},
               media_key,
               "media-msg-2"
             )

    assert decoded.direct_path == "/mms/image/new-path"
    assert decoded.result == :SUCCESS
    assert decoded.message_secret == <<1, 2, 3, 4>>
  end

  test "apply_media_update/3 updates media content with the refreshed direct path and url" do
    media_key = :binary.copy(<<6>>, 32)
    iv = :binary.copy(<<10>>, 12)

    notification = %MediaRetryNotification{
      stanza_id: "media-msg-3",
      direct_path: "/mms/image/refreshed",
      result: :SUCCESS
    }

    assert {:ok, retry_key} =
             Crypto.hkdf(media_key, "WhatsApp Media Retry Notification", 32)

    {:ok, ciphertext} =
      Crypto.aes_gcm_encrypt(
        retry_key,
        iv,
        MediaRetryNotification.encode(notification),
        "media-msg-3"
      )

    message = %Message{
      image_message: %Message.ImageMessage{
        media_key: media_key,
        direct_path: "/mms/image/stale",
        url: nil
      }
    }

    update_event = %{
      key: %{id: "media-msg-3"},
      media: %{ciphertext: ciphertext, iv: iv}
    }

    assert {:ok, %Message{image_message: image_message}} =
             Retry.apply_media_update(message, media_key, update_event)

    assert image_message.direct_path == "/mms/image/refreshed"
    assert image_message.url == "https://mmg.whatsapp.net/mms/image/refreshed"
  end

  test "apply_media_update/3 returns a status-mapped error when the retry result is not success" do
    media_key = :binary.copy(<<11>>, 32)
    iv = :binary.copy(<<12>>, 12)

    notification = %MediaRetryNotification{
      stanza_id: "media-msg-4",
      direct_path: nil,
      result: :NOT_FOUND
    }

    assert {:ok, retry_key} =
             Crypto.hkdf(media_key, "WhatsApp Media Retry Notification", 32)

    {:ok, ciphertext} =
      Crypto.aes_gcm_encrypt(
        retry_key,
        iv,
        MediaRetryNotification.encode(notification),
        "media-msg-4"
      )

    message = %Message{
      image_message: %Message.ImageMessage{
        media_key: media_key,
        direct_path: "/mms/image/stale"
      }
    }

    update_event = %{
      key: %{id: "media-msg-4"},
      media: %{ciphertext: ciphertext, iv: iv}
    }

    assert {:error, {:media_retry_failed, details}} =
             Retry.apply_media_update(message, media_key, update_event)

    assert details.result == :NOT_FOUND
    assert details.status_code == 404
  end

  describe "update_media_message/4" do
    setup do
      media_key = :binary.copy(<<42>>, 32)
      msg_id = "update-media-msg-1"
      iv = :binary.copy(<<17>>, 12)

      wa_message = %WebMessageInfo{
        key: %MessageKey{
          id: msg_id,
          remote_jid: "15551234567@s.whatsapp.net",
          from_me: false,
          participant: nil
        },
        message: %Message{
          image_message: %Message.ImageMessage{
            media_key: media_key,
            direct_path: "/mms/image/stale-path",
            url: "https://mmg.whatsapp.net/mms/image/stale-path"
          }
        }
      }

      {:ok, retry_key} = Crypto.hkdf(media_key, "WhatsApp Media Retry Notification", 32)

      notification = %MediaRetryNotification{
        stanza_id: msg_id,
        direct_path: "/mms/image/refreshed-path",
        result: :SUCCESS
      }

      {:ok, ciphertext} =
        Crypto.aes_gcm_encrypt(
          retry_key,
          iv,
          MediaRetryNotification.encode(notification),
          msg_id
        )

      %{
        wa_message: wa_message,
        media_key: media_key,
        msg_id: msg_id,
        iv: iv,
        ciphertext: ciphertext
      }
    end

    test "successful request-wait-apply round trip", ctx do
      parent = self()
      {:ok, emitter} = EventEmitter.start_link()

      # Simulate sending (capture the node, return :ok)
      send_fun = fn _socket, %BinaryNode{} ->
        send(parent, :node_sent)
        :ok
      end

      # Start the update in a task so we can deliver the event from the test process
      task =
        Task.async(fn ->
          Retry.update_media_message(:fake_socket, emitter, ctx.wa_message,
            me_id: "15550001111@s.whatsapp.net",
            iv: ctx.iv,
            send_fun: send_fun,
            timeout: 5_000
          )
        end)

      # Wait until the node is sent (subscription is active)
      assert_receive :node_sent, 2_000

      # Deliver the matching media update event
      EventEmitter.emit(emitter, :messages_media_update, [
        %{
          key: %{
            id: ctx.msg_id,
            remote_jid: "15551234567@s.whatsapp.net",
            from_me: false,
            participant: nil
          },
          media: %{ciphertext: ctx.ciphertext, iv: ctx.iv}
        }
      ])

      assert {:ok, %WebMessageInfo{message: updated_message}} = Task.await(task, 5_000)

      assert updated_message.image_message.direct_path == "/mms/image/refreshed-path"

      assert updated_message.image_message.url ==
               "https://mmg.whatsapp.net/mms/image/refreshed-path"
    end

    test "times out when no matching update arrives", ctx do
      {:ok, emitter} = EventEmitter.start_link()

      send_fun = fn _socket, %BinaryNode{} -> :ok end

      assert {:error, :media_update_timeout} =
               Retry.update_media_message(:fake_socket, emitter, ctx.wa_message,
                 me_id: "15550001111@s.whatsapp.net",
                 iv: ctx.iv,
                 send_fun: send_fun,
                 timeout: 100
               )
    end

    test "propagates error from request_reupload failure", ctx do
      {:ok, emitter} = EventEmitter.start_link()

      send_fun = fn _socket, %BinaryNode{} -> {:error, :not_connected} end

      assert {:error, :not_connected} =
               Retry.update_media_message(:fake_socket, emitter, ctx.wa_message,
                 me_id: "15550001111@s.whatsapp.net",
                 iv: ctx.iv,
                 send_fun: send_fun,
                 timeout: 5_000
               )
    end

    test "returns error when message is not a media message" do
      {:ok, emitter} = EventEmitter.start_link()

      wa_message = %WebMessageInfo{
        key: %MessageKey{
          id: "text-msg",
          remote_jid: "15551234567@s.whatsapp.net",
          from_me: false
        },
        message: %Message{conversation: "hello"}
      }

      assert {:error, :not_a_media_message} =
               Retry.update_media_message(:fake_socket, emitter, wa_message,
                 me_id: "15550001111@s.whatsapp.net",
                 timeout: 100
               )
    end

    test "returns error for media update with error payload", ctx do
      parent = self()
      {:ok, emitter} = EventEmitter.start_link()

      send_fun = fn _socket, %BinaryNode{} ->
        send(parent, :node_sent)
        :ok
      end

      task =
        Task.async(fn ->
          Retry.update_media_message(:fake_socket, emitter, ctx.wa_message,
            me_id: "15550001111@s.whatsapp.net",
            iv: ctx.iv,
            send_fun: send_fun,
            timeout: 5_000
          )
        end)

      assert_receive :node_sent, 2_000

      # Deliver an error event
      EventEmitter.emit(emitter, :messages_media_update, [
        %{
          key: %{
            id: ctx.msg_id,
            remote_jid: "15551234567@s.whatsapp.net",
            from_me: false,
            participant: nil
          },
          error: %{code: 404, result: :NOT_FOUND, status_code: 404, attrs: %{}}
        }
      ])

      assert {:error, {:media_retry_failed, _details}} = Task.await(task, 5_000)
    end

    test "ignores non-matching message IDs and waits for the right one", ctx do
      parent = self()
      {:ok, emitter} = EventEmitter.start_link()

      send_fun = fn _socket, %BinaryNode{} ->
        send(parent, :node_sent)
        :ok
      end

      task =
        Task.async(fn ->
          Retry.update_media_message(:fake_socket, emitter, ctx.wa_message,
            me_id: "15550001111@s.whatsapp.net",
            iv: ctx.iv,
            send_fun: send_fun,
            timeout: 5_000
          )
        end)

      assert_receive :node_sent, 2_000

      # Emit an event with a different message ID — should be ignored
      EventEmitter.emit(emitter, :messages_media_update, [
        %{
          key: %{
            id: "other-msg-id",
            remote_jid: "other@s.whatsapp.net",
            from_me: false,
            participant: nil
          },
          media: %{ciphertext: <<>>, iv: <<>>}
        }
      ])

      # Small delay to prove the non-matching one didn't resolve
      Process.sleep(50)
      refute Task.yield(task, 0)

      # Now emit the correct one
      EventEmitter.emit(emitter, :messages_media_update, [
        %{
          key: %{
            id: ctx.msg_id,
            remote_jid: "15551234567@s.whatsapp.net",
            from_me: false,
            participant: nil
          },
          media: %{ciphertext: ctx.ciphertext, iv: ctx.iv}
        }
      ])

      assert {:ok, %WebMessageInfo{message: updated}} = Task.await(task, 5_000)
      assert updated.image_message.direct_path == "/mms/image/refreshed-path"
    end
  end

  describe "assert_media_content/1" do
    test "returns image message content" do
      msg = %Message{image_message: %Message.ImageMessage{media_key: <<1>>}}
      assert {:ok, %Message.ImageMessage{}} = Retry.assert_media_content(msg)
    end

    test "returns video message content" do
      msg = %Message{video_message: %Message.VideoMessage{media_key: <<1>>}}
      assert {:ok, %Message.VideoMessage{}} = Retry.assert_media_content(msg)
    end

    test "returns audio message content" do
      msg = %Message{audio_message: %Message.AudioMessage{media_key: <<1>>}}
      assert {:ok, %Message.AudioMessage{}} = Retry.assert_media_content(msg)
    end

    test "returns document message content" do
      msg = %Message{document_message: %Message.DocumentMessage{media_key: <<1>>}}
      assert {:ok, %Message.DocumentMessage{}} = Retry.assert_media_content(msg)
    end

    test "returns sticker message content" do
      msg = %Message{sticker_message: %Message.StickerMessage{media_key: <<1>>}}
      assert {:ok, %Message.StickerMessage{}} = Retry.assert_media_content(msg)
    end

    test "returns error for non-media message" do
      msg = %Message{conversation: "hello"}
      assert {:error, :not_a_media_message} = Retry.assert_media_content(msg)
    end

    test "returns error for nil" do
      assert {:error, :not_a_media_message} = Retry.assert_media_content(nil)
    end
  end
end
