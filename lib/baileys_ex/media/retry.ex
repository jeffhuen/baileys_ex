defmodule BaileysEx.Media.Retry do
  @moduledoc """
  Media re-upload request helpers modeled after Baileys' media retry flow.
  """

  alias BaileysEx.BinaryNode
  alias BaileysEx.Connection.EventEmitter
  alias BaileysEx.Connection.Socket
  alias BaileysEx.Crypto
  alias BaileysEx.Protocol.BinaryNode, as: BinaryNodeUtil
  alias BaileysEx.Protocol.JID, as: JIDUtil
  alias BaileysEx.Protocol.Proto.MediaRetryNotification
  alias BaileysEx.Protocol.Proto.Message
  alias BaileysEx.Protocol.Proto.MessageKey
  alias BaileysEx.Protocol.Proto.ServerErrorReceipt
  alias BaileysEx.Protocol.Proto.WebMessageInfo

  @mmg_host "https://mmg.whatsapp.net"
  @retry_info "WhatsApp Media Retry Notification"
  @status_by_result %{
    SUCCESS: 200,
    DECRYPTION_ERROR: 412,
    NOT_FOUND: 404,
    GENERAL_ERROR: 418
  }

  @type message_key :: %{
          required(:id) => String.t(),
          required(:remote_jid) => String.t(),
          optional(:from_me) => boolean(),
          optional(:participant) => String.t() | nil
        }

  @type media_update_event :: %{
          required(:key) => %{
            id: String.t() | nil,
            remote_jid: String.t() | nil,
            from_me: boolean(),
            participant: String.t() | nil
          },
          optional(:media) => %{ciphertext: binary(), iv: binary()},
          optional(:error) => map()
        }

  @typedoc false
  @type decrypted_media_update :: MediaRetryNotification.t()

  @typedoc false
  @type wa_message :: Message.t()

  @doc """
  Build the Baileys-style `server-error` receipt requesting media re-upload.
  """
  @spec build_retry_request(message_key(), binary(), String.t(), keyword()) ::
          {:ok, BinaryNode.t()} | {:error, term()}
  def build_retry_request(%{id: id, remote_jid: remote_jid} = key, media_key, me_id, opts \\ [])
      when is_binary(id) and is_binary(remote_jid) and is_binary(media_key) and is_binary(me_id) do
    iv = Keyword.get_lazy(opts, :iv, fn -> :crypto.strong_rand_bytes(12) end)

    with {:ok, retry_key} <- media_retry_key(media_key),
         ciphertext <-
           ServerErrorReceipt.encode(%ServerErrorReceipt{stanza_id: id})
           |> encrypt_retry_payload(retry_key, iv, id) do
      {:ok,
       %BinaryNode{
         tag: "receipt",
         attrs: %{
           "id" => id,
           "to" => JIDUtil.normalized_user(me_id),
           "type" => "server-error"
         },
         content: [
           %BinaryNode{
             tag: "encrypt",
             attrs: %{},
             content: [
               %BinaryNode{tag: "enc_p", attrs: %{}, content: {:binary, ciphertext}},
               %BinaryNode{tag: "enc_iv", attrs: %{}, content: {:binary, iv}}
             ]
           },
           %BinaryNode{
             tag: "rmr",
             attrs: %{
               "jid" => remote_jid,
               "from_me" => to_string(Map.get(key, :from_me, false)),
               "participant" => Map.get(key, :participant)
             }
           }
         ]
       }}
    end
  end

  @doc """
  Send a media re-upload request for the given message key.
  """
  @spec request_reupload(GenServer.server() | term(), message_key(), binary(), keyword()) ::
          :ok | {:error, term()}
  def request_reupload(socket, key, media_key, opts \\ []) do
    me_id = Keyword.fetch!(opts, :me_id)
    send_fun = Keyword.get(opts, :send_fun, &Socket.send_node/2)

    with {:ok, node} <- build_retry_request(key, media_key, me_id, opts) do
      send_fun.(socket, node)
    end
  end

  @default_timeout_ms 10_000

  @doc """
  Composed helper that performs the full media re-upload round trip.

  Mirrors Baileys' `updateMediaMessage`: sends the retry request, subscribes to
  `:messages_media_update` events, waits for the matching message ID, decrypts the
  retry payload, and applies the refreshed `directPath`/`url` to the message.

  Returns `{:ok, updated_web_message_info}` or `{:error, reason}`.

  ## Options

    * `:timeout` — milliseconds to wait for the media update event (default `#{@default_timeout_ms}`)
    * `:me_id` — the caller's JID (required)
    * `:send_fun` — override the node send function (default `Socket.send_node/2`)
    * `:iv` — deterministic IV for testing

  """
  @spec update_media_message(
          GenServer.server() | term(),
          GenServer.server(),
          WebMessageInfo.t(),
          keyword()
        ) :: {:ok, WebMessageInfo.t()} | {:error, term()}
  def update_media_message(socket, event_emitter, %WebMessageInfo{} = wa_message, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @default_timeout_ms)

    with {:ok, %MessageKey{id: msg_id} = key} when is_binary(msg_id) <-
           extract_message_key(wa_message),
         {:ok, media_content} <- assert_media_content(wa_message.message),
         media_key when is_binary(media_key) <- media_key_from(media_content) do
      caller = self()
      ref = make_ref()

      unsubscribe =
        EventEmitter.process(event_emitter, fn events ->
          case events do
            %{messages_media_update: updates} when is_list(updates) ->
              case Enum.find(updates, &(&1.key.id == msg_id)) do
                nil -> :ok
                match -> send(caller, {ref, match})
              end

            _ ->
              :ok
          end
        end)

      retry_key = %{
        id: msg_id,
        remote_jid: key.remote_jid || "",
        from_me: key.from_me || false,
        participant: key.participant
      }

      send_result = request_reupload(socket, retry_key, media_key, opts)

      case send_result do
        :ok ->
          result = await_media_update(ref, wa_message, media_key, timeout)
          unsubscribe.()

          case result do
            {:ok, updated_msg} ->
              emit_messages_update(event_emitter, updated_msg)
              {:ok, updated_msg}

            error ->
              error
          end

        {:error, _} = err ->
          unsubscribe.()
          err
      end
    else
      {:error, _} = err -> err
      nil -> {:error, :missing_media_key}
    end
  end

  defp extract_message_key(%WebMessageInfo{key: %MessageKey{id: id} = key})
       when is_binary(id) do
    {:ok, key}
  end

  defp extract_message_key(%WebMessageInfo{}) do
    {:error, :missing_message_key}
  end

  @doc """
  Extract the media-bearing content from a `Message`, mirroring Baileys'
  `assertMediaContent`.

  Returns `{:ok, media_content}` or `{:error, :not_a_media_message}`.
  """
  @spec assert_media_content(Message.t() | nil) ::
          {:ok, struct()} | {:error, :not_a_media_message}
  def assert_media_content(%Message{} = msg) do
    content =
      msg.document_message ||
        msg.image_message ||
        msg.video_message ||
        msg.audio_message ||
        msg.sticker_message

    if content do
      {:ok, content}
    else
      {:error, :not_a_media_message}
    end
  end

  def assert_media_content(_), do: {:error, :not_a_media_message}

  defp media_key_from(%{media_key: media_key}) when is_binary(media_key), do: media_key
  defp media_key_from(_), do: nil

  defp await_media_update(ref, wa_message, media_key, timeout) do
    receive do
      {^ref, %{error: _} = update_event} ->
        case apply_media_update(wa_message.message, media_key, update_event) do
          {:error, _} = err -> err
          # Should not happen for error events, but handle gracefully
          {:ok, _} = ok -> ok
        end

      {^ref, update_event} ->
        case apply_media_update(wa_message.message, media_key, update_event) do
          {:ok, updated_message} ->
            {:ok, %{wa_message | message: updated_message}}

          {:error, _} = err ->
            err
        end
    after
      timeout -> {:error, :media_update_timeout}
    end
  end

  @doc """
  Decode a `mediaretry` notification node into a parity-shaped event payload.
  """
  @spec decode_notification_event(BinaryNode.t()) :: media_update_event()
  def decode_notification_event(%BinaryNode{} = node) do
    rmr = BinaryNodeUtil.child(node, "rmr")

    event = %{
      key: %{
        id: node.attrs["id"],
        remote_jid: rmr && rmr.attrs["jid"],
        from_me: rmr && rmr.attrs["from_me"] == "true",
        participant: rmr && rmr.attrs["participant"]
      }
    }

    case BinaryNodeUtil.child(node, "error") do
      %BinaryNode{attrs: attrs} ->
        Map.put(event, :error, error_details(attrs))

      nil ->
        encrypt = BinaryNodeUtil.child(node, "encrypt")
        ciphertext = BinaryNodeUtil.child_bytes(encrypt, "enc_p")
        iv = BinaryNodeUtil.child_bytes(encrypt, "enc_iv")

        if is_binary(ciphertext) and is_binary(iv) do
          Map.put(event, :media, %{ciphertext: ciphertext, iv: iv})
        else
          Map.put(event, :error, %{reason: :missing_ciphertext, status_code: 404, attrs: %{}})
        end
    end
  end

  @doc """
  Decrypt the encrypted media-update payload returned by the paired device.
  """
  @spec decrypt_media_update(%{ciphertext: binary(), iv: binary()}, binary(), String.t()) ::
          {:ok, decrypted_media_update()} | {:error, term()}
  def decrypt_media_update(%{ciphertext: ciphertext, iv: iv}, media_key, msg_id)
      when is_binary(ciphertext) and is_binary(iv) and is_binary(media_key) and is_binary(msg_id) do
    with {:ok, retry_key} <- media_retry_key(media_key),
         {:ok, plaintext} <- Crypto.aes_gcm_decrypt(retry_key, iv, ciphertext, msg_id) do
      MediaRetryNotification.decode(plaintext)
    end
  end

  @doc """
  Apply a media-update event to a media message after decrypting the retry data.
  """
  @spec apply_media_update(wa_message(), binary(), media_update_event()) ::
          {:ok, wa_message()} | {:error, term()}
  def apply_media_update(%Message{}, media_key, %{error: error}) when is_binary(media_key) do
    {:error, {:media_retry_failed, error}}
  end

  def apply_media_update(%Message{} = message, media_key, %{key: %{id: id}, media: media})
      when is_binary(media_key) and is_binary(id) do
    with {:ok, notification} <- decrypt_media_update(media, media_key, id),
         :ok <- ensure_retry_success(notification) do
      put_direct_path(message, notification.direct_path)
    end
  end

  def apply_media_update(%Message{}, _media_key, _event), do: {:error, :invalid_media_update}

  @doc """
  Map a media retry result to the HTTP-style status Baileys uses.
  """
  @spec status_code_for_result(atom() | integer()) :: pos_integer() | nil
  def status_code_for_result(result) when is_atom(result), do: Map.get(@status_by_result, result)

  def status_code_for_result(result) when is_integer(result),
    do: result |> result_atom() |> status_code_for_result()

  def status_code_for_result(_result), do: nil

  defp media_retry_key(media_key) do
    Crypto.hkdf(media_key, @retry_info, 32)
  end

  defp encrypt_retry_payload(payload, retry_key, iv, aad) do
    {:ok, ciphertext} = Crypto.aes_gcm_encrypt(retry_key, iv, payload, aad)
    ciphertext
  end

  defp error_details(attrs) do
    code =
      case Integer.parse(to_string(attrs["code"] || "")) do
        {value, ""} -> value
        _ -> nil
      end

    result = result_atom(code)

    %{
      code: code,
      result: result,
      status_code: status_code_for_result(result || code),
      attrs: attrs
    }
  end

  defp ensure_retry_success(%MediaRetryNotification{result: :SUCCESS}), do: :ok

  defp ensure_retry_success(%MediaRetryNotification{result: result} = notification) do
    {:error,
     {:media_retry_failed,
      %{
        result: result,
        status_code: status_code_for_result(result),
        notification: notification
      }}}
  end

  defp put_direct_path(
         %Message{image_message: %Message.ImageMessage{} = content} = message,
         direct_path
       )
       when is_binary(direct_path) do
    {:ok,
     %{
       message
       | image_message: %{content | direct_path: direct_path, url: media_url(direct_path)}
     }}
  end

  defp put_direct_path(
         %Message{video_message: %Message.VideoMessage{} = content} = message,
         direct_path
       )
       when is_binary(direct_path) do
    {:ok,
     %{
       message
       | video_message: %{content | direct_path: direct_path, url: media_url(direct_path)}
     }}
  end

  defp put_direct_path(
         %Message{audio_message: %Message.AudioMessage{} = content} = message,
         direct_path
       )
       when is_binary(direct_path) do
    {:ok,
     %{
       message
       | audio_message: %{content | direct_path: direct_path, url: media_url(direct_path)}
     }}
  end

  defp put_direct_path(
         %Message{document_message: %Message.DocumentMessage{} = content} = message,
         direct_path
       )
       when is_binary(direct_path) do
    {:ok,
     %{
       message
       | document_message: %{content | direct_path: direct_path, url: media_url(direct_path)}
     }}
  end

  defp put_direct_path(
         %Message{sticker_message: %Message.StickerMessage{} = content} = message,
         direct_path
       )
       when is_binary(direct_path) do
    {:ok,
     %{
       message
       | sticker_message: %{content | direct_path: direct_path, url: media_url(direct_path)}
     }}
  end

  defp put_direct_path(%Message{}, _direct_path), do: {:error, :unsupported_media_message}

  defp media_url(direct_path), do: @mmg_host <> direct_path

  defp result_atom(code) when is_integer(code) do
    Enum.find_value(@status_by_result, fn {result, _status} ->
      if value_for_result_key(result) == code, do: result
    end)
  end

  defp result_atom(_code), do: nil

  defp value_for_result_key(:GENERAL_ERROR), do: 0
  defp value_for_result_key(:SUCCESS), do: 1
  defp value_for_result_key(:NOT_FOUND), do: 2
  defp value_for_result_key(:DECRYPTION_ERROR), do: 3

  # Emit messages_update event after successful media refresh, matching Baileys behavior
  defp emit_messages_update(event_emitter, %WebMessageInfo{key: key} = msg) do
    update = %{key: key, update: %{message: msg.message}}
    EventEmitter.emit(event_emitter, :messages_update, [update])
  rescue
    _ -> :ok
  end
end
