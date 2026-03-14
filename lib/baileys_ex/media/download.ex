defmodule BaileysEx.Media.Download do
  @moduledoc """
  Download and decrypt WhatsApp CDN media referenced by media message structs.
  """

  alias BaileysEx.Crypto, as: CoreCrypto
  alias BaileysEx.Media.HTTP
  alias BaileysEx.Protocol.Proto.Message

  @mmg_host "https://mmg.whatsapp.net"
  @aes_chunk_size 16

  @type media_message :: %{
          optional(:__struct__) => module(),
          optional(:url) => binary(),
          optional(:direct_path) => binary(),
          optional(:media_key) => binary()
        }

  @type download_error ::
          :missing_media_key
          | :missing_media_url
          | :unknown_media_type
          | :invalid_media_payload
          | :invalid_padding
          | {:http_error, pos_integer(), term()}

  @spec download(media_message(), keyword()) :: {:ok, binary()} | {:error, download_error()}
  @doc """
  Download and decrypt media referenced by a WhatsApp media message.

  Supports `:start_byte` and `:end_byte` options for Baileys-style ranged media
  downloads. `:end_byte` is an exclusive upper bound.

  The streamed path decrypts aligned AES-CBC chunks on the fly and does not
  validate the trailing 10-byte media MAC. For full-payload MAC verification,
  use `BaileysEx.Media.Crypto.decrypt/3`.
  """
  def download(media_message, opts \\ []) do
    with {:ok, media_type} <- media_type(media_message, opts),
         {:ok, url} <- media_url(media_message),
         media_key when is_binary(media_key) <- Map.get(media_message, :media_key),
         {:ok, iodata} <- download_into(media_key, media_type, url, opts, [], &collect_chunk/2) do
      {:ok, IO.iodata_to_binary(Enum.reverse(iodata))}
    else
      nil -> {:error, :missing_media_key}
      {:error, _reason} = error -> error
    end
  end

  @spec download_to_file(media_message(), Path.t(), keyword()) ::
          {:ok, Path.t()} | {:error, download_error()}
  @doc """
  Download and decrypt media directly to a file path without buffering the full
  media body in memory.

  Like `download/2`, this uses chunked AES-CBC decryption and does not verify
  the trailing media MAC while streaming.
  """
  def download_to_file(media_message, path, opts \\ []) do
    with {:ok, media_type} <- media_type(media_message, opts),
         {:ok, url} <- media_url(media_message),
         media_key when is_binary(media_key) <- Map.get(media_message, :media_key) do
      File.mkdir_p!(Path.dirname(path))

      case File.open(path, [:write, :binary]) do
        {:ok, device} ->
          try do
            case download_into(media_key, media_type, url, opts, device, &write_chunk/2) do
              {:ok, _device} ->
                {:ok, path}

              {:error, reason} ->
                File.rm(path)
                {:error, reason}
            end
          rescue
            error ->
              File.rm(path)
              reraise(error, __STACKTRACE__)
          catch
            kind, reason ->
              File.rm(path)
              :erlang.raise(kind, reason, __STACKTRACE__)
          after
            File.close(device)
          end

        {:error, reason} ->
          {:error, reason}
      end
    else
      nil -> {:error, :missing_media_key}
      {:error, _reason} = error -> error
    end
  end

  defp media_type(%Message.ImageMessage{}, _opts), do: {:ok, :image}
  defp media_type(%Message.VideoMessage{}, _opts), do: {:ok, :video}
  defp media_type(%Message.AudioMessage{}, _opts), do: {:ok, :audio}
  defp media_type(%Message.DocumentMessage{}, _opts), do: {:ok, :document}
  defp media_type(%Message.StickerMessage{}, _opts), do: {:ok, :sticker}

  defp media_type(_media_message, opts) do
    case opts[:media_type] do
      nil -> {:error, :unknown_media_type}
      media_type -> {:ok, media_type}
    end
  end

  defp media_url(%{url: url, direct_path: direct_path})
       when is_binary(url) and byte_size(url) > 0 and is_binary(direct_path) and
              byte_size(direct_path) > 0 do
    if String.starts_with?(url, @mmg_host) do
      {:ok, url}
    else
      {:ok, @mmg_host <> direct_path}
    end
  end

  defp media_url(%{url: url}) when is_binary(url) and byte_size(url) > 0 do
    if String.starts_with?(url, @mmg_host) do
      {:ok, url}
    else
      {:error, :missing_media_url}
    end
  end

  defp media_url(%{direct_path: direct_path})
       when is_binary(direct_path) and byte_size(direct_path) > 0,
       do: {:ok, @mmg_host <> direct_path}

  defp media_url(_media_message), do: {:error, :missing_media_url}

  defp download_into(media_key, media_type, url, opts, acc, sink_fun) do
    %{iv: iv, cipher_key: cipher_key} = CoreCrypto.expand_media_key(media_key, media_type)
    decrypt_opts = range_options(opts)
    decrypt_state = new_decrypt_state(iv, cipher_key, decrypt_opts)

    case fetch_media_stream(url, decrypt_opts, opts) do
      {:ok, response_stream} ->
        decrypt_stream(response_stream, decrypt_state, acc, sink_fun)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp fetch_media_stream(url, decrypt_opts, opts) do
    request_fun = opts[:request_fun] || (&Req.get/1)
    req_options = opts[:req_options] || []

    headers =
      req_options[:headers]
      |> HTTP.merge_headers([{"origin", "https://web.whatsapp.com"}])
      |> maybe_add_range_header(decrypt_opts)

    request_opts =
      req_options
      |> Keyword.drop([:headers])
      |> Keyword.merge(
        url: url,
        headers: headers,
        decode_body: false,
        into: :self
      )

    case request_fun.(request_opts) do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
        {:ok, to_chunk_stream(body)}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:http_error, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp decrypt_stream(response_stream, state, acc, sink_fun) do
    {acc, state} =
      Enum.reduce(response_stream, {acc, state}, fn chunk, {acc, state} ->
        {:ok, next_acc, next_state} = decrypt_chunk(chunk, state, acc, sink_fun)
        {next_acc, next_state}
      end)

    finalize_decrypt(state, acc, sink_fun)
  end

  defp decrypt_chunk(chunk, state, acc, sink_fun) when is_binary(chunk) do
    data = state.pending <> chunk
    decrypt_length = to_smallest_chunk_size(byte_size(data))
    <<decryptable::binary-size(decrypt_length), pending::binary>> = data

    {state, decryptable} = maybe_init_cipher_state(state, decryptable)

    case decryptable do
      <<>> ->
        {:ok, acc, %{state | pending: pending}}

      _ ->
        plaintext = :crypto.crypto_update(state.cipher_state, decryptable)
        emit_plaintext(plaintext, %{state | pending: pending}, acc, sink_fun)
    end
  end

  defp finalize_decrypt(%{cipher_state: nil, pending: <<>>}, _acc, _sink_fun),
    do: {:error, :invalid_media_payload}

  defp finalize_decrypt(%{cipher_state: nil}, _acc, _sink_fun),
    do: {:error, :invalid_media_payload}

  defp finalize_decrypt(state, acc, sink_fun) do
    plaintext = state.plaintext_tail <> :crypto.crypto_final(state.cipher_state)

    with {:ok, plaintext} <- finalize_plaintext(plaintext, state.end_byte),
         {:ok, acc, _bytes_fetched} <-
           push_bytes(
             plaintext,
             acc,
             state.bytes_fetched,
             state.start_byte,
             state.end_byte,
             sink_fun
           ) do
      {:ok, acc}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp maybe_init_cipher_state(%{cipher_state: nil} = state, decryptable) do
    if decryptable == <<>> and not state.first_block_is_iv do
      {state, decryptable}
    else
      {iv, decryptable, first_block_is_iv} = initial_iv(state, decryptable)

      if decryptable == <<>> and first_block_is_iv do
        {state, decryptable}
      else
        {put_cipher_state(state, iv, first_block_is_iv), decryptable}
      end
    end
  end

  defp maybe_init_cipher_state(state, decryptable), do: {state, decryptable}

  defp initial_iv(%{first_block_is_iv: false, iv: iv}, decryptable), do: {iv, decryptable, false}

  defp initial_iv(%{iv: iv} = state, decryptable) do
    case decryptable do
      <<next_iv::binary-size(@aes_chunk_size), rest::binary>> -> {next_iv, rest, false}
      _ -> {iv, decryptable, state.first_block_is_iv}
    end
  end

  defp put_cipher_state(state, iv, first_block_is_iv) do
    %{
      state
      | cipher_state: init_cipher_state(state.cipher_key, iv, state.end_byte),
        first_block_is_iv: first_block_is_iv
    }
  end

  defp init_cipher_state(cipher_key, iv, end_byte) do
    :crypto.crypto_init(:aes_256_cbc, cipher_key, iv, crypto_init_options(end_byte))
  end

  defp crypto_init_options(nil), do: [encrypt: false]
  defp crypto_init_options(_end_byte), do: [encrypt: false, padding: :none]

  defp emit_plaintext(plaintext, %{end_byte: nil} = state, acc, sink_fun) do
    data = state.plaintext_tail <> plaintext

    if byte_size(data) > @aes_chunk_size do
      push_size = byte_size(data) - @aes_chunk_size
      <<to_push::binary-size(push_size), tail::binary-size(@aes_chunk_size)>> = data

      with {:ok, acc, bytes_fetched} <-
             push_bytes(
               to_push,
               acc,
               state.bytes_fetched,
               state.start_byte,
               state.end_byte,
               sink_fun
             ) do
        {:ok, acc, %{state | plaintext_tail: tail, bytes_fetched: bytes_fetched}}
      end
    else
      {:ok, acc, %{state | plaintext_tail: data}}
    end
  end

  defp emit_plaintext(plaintext, state, acc, sink_fun) do
    with {:ok, acc, bytes_fetched} <-
           push_bytes(
             plaintext,
             acc,
             state.bytes_fetched,
             state.start_byte,
             state.end_byte,
             sink_fun
           ) do
      {:ok, acc, %{state | bytes_fetched: bytes_fetched}}
    end
  end

  defp finalize_plaintext(plaintext, nil), do: CoreCrypto.pkcs7_unpad(plaintext, @aes_chunk_size)
  defp finalize_plaintext(plaintext, _end_byte), do: {:ok, plaintext}

  defp push_bytes(bytes, acc, bytes_fetched, start_byte, end_byte, sink_fun) do
    {bytes_to_push, next_bytes_fetched} =
      slice_for_requested_range(bytes, bytes_fetched, start_byte, end_byte)

    {:ok, acc} = sink_fun.(bytes_to_push, acc)
    {:ok, acc, next_bytes_fetched}
  end

  defp slice_for_requested_range(bytes, bytes_fetched, start_byte, end_byte)
       when not is_integer(start_byte) and not is_integer(end_byte) do
    {bytes, bytes_fetched}
  end

  defp slice_for_requested_range(bytes, bytes_fetched, start_byte, end_byte) do
    start_index = range_start_index(bytes_fetched, start_byte)
    end_index = range_end_index(bytes_fetched, byte_size(bytes), end_byte)
    {slice_range(bytes, start_index, end_index), bytes_fetched + byte_size(bytes)}
  end

  defp range_start_index(bytes_fetched, start_byte)
       when is_integer(start_byte) and bytes_fetched < start_byte do
    max(start_byte - bytes_fetched, 0)
  end

  defp range_start_index(_bytes_fetched, _start_byte), do: 0

  defp range_end_index(bytes_fetched, byte_count, end_byte)
       when is_integer(end_byte) and bytes_fetched + byte_count >= end_byte do
    max(end_byte - bytes_fetched, 0)
  end

  defp range_end_index(_bytes_fetched, byte_count, _end_byte), do: byte_count

  defp slice_range(bytes, start_index, end_index) when end_index > start_index,
    do: binary_part(bytes, start_index, end_index - start_index)

  defp slice_range(_bytes, _start_index, _end_index), do: <<>>

  defp collect_chunk(<<>>, acc), do: {:ok, acc}
  defp collect_chunk(bytes, acc), do: {:ok, [bytes | acc]}

  defp write_chunk(<<>>, device), do: {:ok, device}

  defp write_chunk(bytes, device) do
    :ok = IO.binwrite(device, bytes)
    {:ok, device}
  end

  defp to_chunk_stream(body) when is_binary(body), do: [body]
  defp to_chunk_stream(body), do: body

  defp new_decrypt_state(iv, cipher_key, decrypt_opts) do
    %{
      iv: iv,
      cipher_key: cipher_key,
      start_byte: decrypt_opts.start_byte,
      end_byte: decrypt_opts.end_byte,
      pending: <<>>,
      plaintext_tail: <<>>,
      bytes_fetched: decrypt_opts.bytes_fetched,
      first_block_is_iv: decrypt_opts.first_block_is_iv,
      cipher_state: nil
    }
  end

  defp range_options(opts) do
    start_byte = opts[:start_byte]
    end_byte = opts[:end_byte]

    if is_integer(start_byte) and start_byte > 0 do
      chunk = to_smallest_chunk_size(start_byte)

      if chunk > 0 do
        %{
          start_byte: start_byte,
          end_byte: end_byte,
          start_chunk: chunk - @aes_chunk_size,
          end_chunk:
            if(is_integer(end_byte),
              do: to_smallest_chunk_size(end_byte) + @aes_chunk_size,
              else: nil
            ),
          bytes_fetched: chunk,
          first_block_is_iv: true
        }
      else
        %{
          start_byte: start_byte,
          end_byte: end_byte,
          start_chunk: 0,
          end_chunk:
            if(is_integer(end_byte),
              do: to_smallest_chunk_size(end_byte) + @aes_chunk_size,
              else: nil
            ),
          bytes_fetched: 0,
          first_block_is_iv: false
        }
      end
    else
      %{
        start_byte: start_byte,
        end_byte: end_byte,
        start_chunk: 0,
        end_chunk:
          if(is_integer(end_byte),
            do: to_smallest_chunk_size(end_byte) + @aes_chunk_size,
            else: nil
          ),
        bytes_fetched: 0,
        first_block_is_iv: false
      }
    end
  end

  defp maybe_add_range_header(headers, %{start_chunk: 0, end_chunk: nil}), do: headers

  defp maybe_add_range_header(headers, %{start_chunk: start_chunk, end_chunk: end_chunk}) do
    range_value =
      case end_chunk do
        nil -> "bytes=#{start_chunk}-"
        _ -> "bytes=#{start_chunk}-#{end_chunk}"
      end

    HTTP.merge_headers(headers, [{"range", range_value}])
  end

  defp to_smallest_chunk_size(num), do: div(num, @aes_chunk_size) * @aes_chunk_size
end
