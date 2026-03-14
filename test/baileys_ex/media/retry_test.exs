defmodule BaileysEx.Media.RetryTest do
  use ExUnit.Case, async: true

  alias BaileysEx.BinaryNode
  alias BaileysEx.Crypto
  alias BaileysEx.Media.Retry
  alias BaileysEx.Protocol.BinaryNode, as: BinaryNodeUtil
  alias BaileysEx.Protocol.Proto.MediaRetryNotification
  alias BaileysEx.Protocol.Proto.Message
  alias BaileysEx.Protocol.Proto.ServerErrorReceipt

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
end
