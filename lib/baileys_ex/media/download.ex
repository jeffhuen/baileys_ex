defmodule BaileysEx.Media.Download do
  @moduledoc """
  Download and decrypt WhatsApp CDN media referenced by media message structs.
  """

  alias BaileysEx.Crypto, as: CoreCrypto
  alias BaileysEx.Media.HTTP
  alias BaileysEx.Protocol.Proto.Message
  alias BaileysEx.Telemetry

  @default_media_host "mmg.whatsapp.net"
  @placeholder_media_host "a.whatsapp.net"
  @aes_chunk_size 16
  @max_error_body_bytes 64 * 1024

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
    Telemetry.span(
      [:media, :download],
      %{media_type: telemetry_media_type(media_message, opts), target: :memory},
      fn ->
        with {:ok, media_type} <- media_type(media_message, opts),
             {:ok, url} <- media_url(media_message, opts),
             media_key when is_binary(media_key) <- Map.get(media_message, :media_key),
             {:ok, iodata} <-
               download_into(media_key, media_type, url, opts, [], &collect_chunk/2) do
          {:ok, IO.iodata_to_binary(Enum.reverse(iodata))}
        else
          nil -> {:error, :missing_media_key}
          {:error, _reason} = error -> error
        end
      end
    )
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
    Telemetry.span(
      [:media, :download],
      %{media_type: telemetry_media_type(media_message, opts), path: path, target: :file},
      fn ->
        with {:ok, media_type} <- media_type(media_message, opts),
             {:ok, url} <- media_url(media_message, opts),
             media_key when is_binary(media_key) <- Map.get(media_message, :media_key) do
          stream_download_to_file(media_key, media_type, url, path, opts)
        else
          nil -> {:error, :missing_media_key}
          {:error, _reason} = error -> error
        end
      end
    )
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

  defp telemetry_media_type(%Message.ImageMessage{}, _opts), do: :image
  defp telemetry_media_type(%Message.VideoMessage{}, _opts), do: :video
  defp telemetry_media_type(%Message.AudioMessage{}, _opts), do: :audio
  defp telemetry_media_type(%Message.DocumentMessage{}, _opts), do: :document
  defp telemetry_media_type(%Message.StickerMessage{}, _opts), do: :sticker
  defp telemetry_media_type(_media_message, opts), do: opts[:media_type]

  defp media_url(%{direct_path: direct_path} = media_message, opts)
       when is_binary(direct_path) and byte_size(direct_path) > 0 do
    host = opts[:host] || extract_host(Map.get(media_message, :url)) || @default_media_host
    {:ok, "https://#{host}#{direct_path}"}
  end

  defp media_url(%{url: url}, _opts) when is_binary(url) and byte_size(url) > 0, do: {:ok, url}

  defp media_url(_media_message, _opts), do: {:error, :missing_media_url}

  defp extract_host(url) when is_binary(url) and byte_size(url) > 0 do
    case URI.parse(url) do
      %URI{host: host} when is_binary(host) ->
        if String.downcase(host) == @placeholder_media_host, do: nil, else: host

      _ ->
        nil
    end
  end

  defp extract_host(_url), do: nil

  defp stream_download_to_file(media_key, media_type, url, path, opts) do
    File.mkdir_p!(Path.dirname(path))

    with_open_file(path, [:write, :binary], fn device ->
      reset_fun = fn -> reset_file_device(device) end

      case download_into(media_key, media_type, url, opts, device, &write_chunk/2, reset_fun) do
        {:ok, _device} ->
          {:ok, path}

        {:error, reason} ->
          cleanup_download_file(path, {:error, reason})
      end
    end)
  end

  defp reset_file_device(device) do
    {:ok, 0} = :file.position(device, :bof)
    :ok = :file.truncate(device)
  end

  defp with_open_file(path, modes, fun) when is_function(fun, 1) do
    case File.open(path, modes) do
      {:ok, device} ->
        try do
          fun.(device)
        rescue
          error ->
            _ = File.rm(path)
            reraise(error, __STACKTRACE__)
        catch
          kind, reason ->
            _ = File.rm(path)
            :erlang.raise(kind, reason, __STACKTRACE__)
        after
          File.close(device)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp cleanup_download_file(path, {:error, reason}) do
    _ = File.rm(path)
    {:error, reason}
  end

  defp download_into(
         media_key,
         media_type,
         url,
         opts,
         acc,
         sink_fun,
         reset_fun \\ &noop_reset/0
       ) do
    %{iv: iv, cipher_key: cipher_key} = CoreCrypto.expand_media_key(media_key, media_type)
    decrypt_opts = range_options(opts)
    decrypt_state = new_decrypt_state(iv, cipher_key, decrypt_opts)
    base_opts = base_request_options(url, decrypt_opts, opts)

    cond do
      is_function(opts[:request_fun], 1) ->
        download_with_request_fun(opts[:request_fun], base_opts, decrypt_state, acc, sink_fun)

      req_stream_supported?() ->
        download_with_req_stream(base_opts, decrypt_state, acc, sink_fun, reset_fun)

      true ->
        download_with_req_into_fun(base_opts, decrypt_state, acc, sink_fun, reset_fun)
    end
  end

  defp noop_reset, do: :ok

  defp base_request_options(url, decrypt_opts, opts) do
    req_options = opts[:req_options] || []

    headers =
      req_options[:headers]
      |> HTTP.merge_headers([{"origin", "https://web.whatsapp.com"}])
      |> maybe_add_range_header(decrypt_opts)

    req_options
    |> Keyword.drop([:headers, :into, :decode_body, :compressed])
    |> Keyword.merge(
      url: url,
      headers: headers,
      raw: true,
      compressed: false,
      decode_body: false,
      into: nil
    )
  end

  defp download_with_request_fun(request_fun, base_opts, decrypt_state, acc, sink_fun) do
    request_opts = Keyword.put(base_opts, :into, :self)

    case request_fun.(request_opts) do
      {:ok, %Req.Response{status: status} = resp} when status in 200..299 ->
        decrypt_response_with_cleanup(resp, decrypt_state, acc, sink_fun)

      {:ok, %Req.Response{} = resp} ->
        consume_or_cancel_error_body(resp)

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Req 0.7 streams both 200 and 206 Partial Content responses with TCP backpressure
  # via `into: fun`. Each retry or redirect starts with a fresh `%Req.Response{}` so
  # private accumulator state naturally resets and `reset_fun` truncates partial files.
  defp download_with_req_into_fun(base_opts, decrypt_state, acc, sink_fun, reset_fun) do
    initial_acc = initial_stream_acc(decrypt_state, acc)

    into_fun = fn {:data, data}, {req, resp} ->
      current_acc = Req.Response.get_private(resp, :baileys_ex_download, initial_acc)
      next_acc = step_stream_chunk(data, resp.status, current_acc, sink_fun, reset_fun)
      {:cont, {req, Req.Response.put_private(resp, :baileys_ex_download, next_acc)}}
    end

    request_opts =
      base_opts
      |> Keyword.drop([:method])
      |> Keyword.put(:into, into_fun)

    case Req.get(request_opts) do
      {:ok, %Req.Response{status: status} = resp} ->
        final_acc = Req.Response.get_private(resp, :baileys_ex_download, initial_acc)
        finalize_stream_response(status, resp.body, final_acc, sink_fun, reset_fun)

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Req 0.8+ replaces `into: fun` with `Req.stream/4`, providing backpressured streaming
  # across both 200 and 206 Partial Content responses without spawning an extra process.
  defp download_with_req_stream(base_opts, decrypt_state, acc, sink_fun, reset_fun) do
    req = Req.new(Keyword.put(base_opts, :method, :get))
    initial_acc = initial_stream_acc(decrypt_state, acc)

    stream_fun = fn
      data, %Req.Response{status: status}, stream_acc when is_binary(data) ->
        {:cont, step_stream_chunk(data, status, stream_acc, sink_fun, reset_fun)}

      _data, _resp, stream_acc ->
        {:cont, stream_acc}
    end

    case call_req_stream(Req, req, initial_acc, stream_fun) do
      {:ok, %Req.Response{status: status} = resp, final_acc} ->
        finalize_stream_response(status, resp.body, final_acc, sink_fun, reset_fun)

      {:error, reason, _resp, _final_acc} ->
        {:error, reason}
    end
  end

  defp initial_stream_acc(decrypt_state, acc) do
    %{
      started?: false,
      decrypt_state: decrypt_state,
      sink_acc: acc,
      error_status: nil,
      error_chunks: [],
      error_bytes: 0
    }
  end

  defp step_stream_chunk(data, status, stream_acc, sink_fun, reset_fun)
       when is_binary(data) and status in 200..299 do
    unless stream_acc.started?, do: :ok = reset_fun.()

    {:ok, next_sink_acc, next_decrypt_state} =
      decrypt_chunk(data, stream_acc.decrypt_state, stream_acc.sink_acc, sink_fun)

    %{
      stream_acc
      | started?: true,
        decrypt_state: next_decrypt_state,
        sink_acc: next_sink_acc
    }
  end

  defp step_stream_chunk(data, status, stream_acc, _sink_fun, _reset_fun) when is_binary(data) do
    append_bounded_error_chunk(stream_acc, status, data)
  end

  defp finalize_stream_response(
         status,
         _resp_body,
         %{started?: true} = final_acc,
         sink_fun,
         _reset_fun
       )
       when status in 200..299 do
    finalize_decrypt(final_acc.decrypt_state, final_acc.sink_acc, sink_fun)
  end

  defp finalize_stream_response(status, resp_body, final_acc, sink_fun, reset_fun)
       when status in 200..299 do
    if empty_response_body?(resp_body) do
      finalize_decrypt(final_acc.decrypt_state, final_acc.sink_acc, sink_fun)
    else
      :ok = reset_fun.()

      decrypt_stream(
        to_chunk_stream(resp_body),
        final_acc.decrypt_state,
        final_acc.sink_acc,
        sink_fun
      )
    end
  end

  defp finalize_stream_response(status, resp_body, final_acc, _sink_fun, _reset_fun) do
    error_body =
      cond do
        final_acc.error_status == status ->
          final_acc.error_chunks |> Enum.reverse() |> IO.iodata_to_binary()

        is_binary(resp_body) ->
          truncate_error_body(resp_body)

        true ->
          ""
      end

    {:error, {:http_error, status, error_body}}
  end

  defp empty_response_body?(nil), do: true
  defp empty_response_body?(<<>>), do: true
  defp empty_response_body?([]), do: true
  defp empty_response_body?(_body), do: false

  defp truncate_error_body(body) when is_binary(body) and byte_size(body) > @max_error_body_bytes,
    do: :binary.copy(binary_part(body, 0, @max_error_body_bytes))

  defp truncate_error_body(body), do: detach_binary(body)

  defp detach_binary(binary) when is_binary(binary) do
    if :binary.referenced_byte_size(binary) > byte_size(binary) do
      :binary.copy(binary)
    else
      binary
    end
  end

  defp detach_binary(other), do: other

  defp call_req_stream(req_module, req, initial_acc, stream_fun) do
    req_module.stream(req, initial_acc, stream_fun, [])
  end

  defp req_stream_supported? do
    Code.ensure_loaded?(Req) and function_exported?(Req, :stream, 4)
  end

  defp append_bounded_error_chunk(%{error_status: status} = stream_acc, status, data) do
    remaining = @max_error_body_bytes - stream_acc.error_bytes

    cond do
      remaining <= 0 ->
        stream_acc

      byte_size(data) <= remaining ->
        %{
          stream_acc
          | error_chunks: [detach_binary(data) | stream_acc.error_chunks],
            error_bytes: stream_acc.error_bytes + byte_size(data)
        }

      true ->
        snippet = :binary.copy(binary_part(data, 0, remaining))

        %{
          stream_acc
          | error_chunks: [snippet | stream_acc.error_chunks],
            error_bytes: @max_error_body_bytes
        }
    end
  end

  defp append_bounded_error_chunk(stream_acc, status, data) do
    stream_acc
    |> Map.merge(%{error_status: status, error_chunks: [], error_bytes: 0})
    |> append_bounded_error_chunk(status, data)
  end

  defp decrypt_response_with_cleanup(
         %Req.Response{body: %Req.Response.Async{}} = resp,
         decrypt_state,
         acc,
         sink_fun
       ) do
    case reduce_async_response(resp, {acc, decrypt_state}, fn chunk, {cur_acc, cur_state} ->
           {:ok, next_acc, next_state} = decrypt_chunk(chunk, cur_state, cur_acc, sink_fun)
           {:cont, {next_acc, next_state}}
         end) do
      {:ok, {final_acc, final_state}} ->
        finalize_decrypt(final_state, final_acc, sink_fun)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp decrypt_response_with_cleanup(%Req.Response{body: body}, decrypt_state, acc, sink_fun) do
    decrypt_stream(to_chunk_stream(body), decrypt_state, acc, sink_fun)
  end

  defp consume_or_cancel_error_body(
         %Req.Response{status: status, body: %Req.Response.Async{}} = resp
       ) do
    case reduce_async_response(resp, {[], 0}, fn chunk, {chunks, size} ->
           collect_bounded_chunk(chunk, chunks, size)
         end) do
      {:ok, {chunks, _size}} ->
        body = chunks |> Enum.reverse() |> IO.iodata_to_binary()
        {:error, {:http_error, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp consume_or_cancel_error_body(%Req.Response{status: status, body: body}) do
    {:error, {:http_error, status, truncate_error_body(body)}}
  end

  defp reduce_async_response(
         %Req.Response{body: %Req.Response.Async{pid: pid, ref: ref}} = resp,
         acc,
         fun
       ) do
    if pid != self() do
      raise ArgumentError,
            "expected to read async response body in #{inspect(pid)}, got #{inspect(self())}"
    end

    case run_async_loop(resp, ref, acc, fun) do
      {:ok, final_acc} ->
        {:ok, final_acc}

      {:halted, halted_acc} ->
        cancel_async_response_once(resp)
        {:ok, halted_acc}

      {:unexpected, other} ->
        cancel_async_response_once(resp)
        {:error, {:unexpected_async_message, other}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp run_async_loop(resp, ref, acc, fun) do
    do_reduce_async_response(resp, ref, acc, fun)
  rescue
    error ->
      cancel_async_response_once(resp)
      reraise(error, __STACKTRACE__)
  catch
    kind, reason ->
      cancel_async_response_once(resp)
      :erlang.raise(kind, reason, __STACKTRACE__)
  end

  defp do_reduce_async_response(resp, ref, acc, fun) do
    receive do
      {^ref, _} = message ->
        handle_async_message(Req.parse_message(resp, message), resp, ref, acc, fun)
    end
  end

  defp handle_async_message({:ok, [data: data]}, resp, ref, acc, fun) do
    case fun.(data, acc) do
      {:cont, next_acc} -> do_reduce_async_response(resp, ref, next_acc, fun)
      {:halt, halted_acc} -> {:halted, halted_acc}
    end
  end

  defp handle_async_message({:ok, [:done]}, _resp, _ref, acc, _fun), do: {:ok, acc}

  defp handle_async_message({:ok, [trailers: _trailers]}, resp, ref, acc, fun) do
    do_reduce_async_response(resp, ref, acc, fun)
  end

  defp handle_async_message({:error, reason}, _resp, _ref, _acc, _fun), do: {:error, reason}
  defp handle_async_message(other, _resp, _ref, _acc, _fun), do: {:unexpected, other}

  defp collect_bounded_chunk(chunk, chunks, size) do
    remaining = @max_error_body_bytes - size

    cond do
      remaining <= 0 ->
        {:halt, {chunks, @max_error_body_bytes}}

      byte_size(chunk) < remaining ->
        {:cont, {[detach_binary(chunk) | chunks], size + byte_size(chunk)}}

      byte_size(chunk) == remaining ->
        {:halt, {[detach_binary(chunk) | chunks], @max_error_body_bytes}}

      true ->
        snippet = :binary.copy(binary_part(chunk, 0, remaining))
        {:halt, {[snippet | chunks], @max_error_body_bytes}}
    end
  end

  defp cancel_async_response_once(%Req.Response{body: %Req.Response.Async{}} = resp) do
    _ = Req.cancel_async_response(resp)
    :ok
  catch
    :exit, _reason -> :ok
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
    <<decryptable::binary-size(^decrypt_length), pending::binary>> = data

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
      <<to_push::binary-size(^push_size), tail::binary-size(@aes_chunk_size)>> = data

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
