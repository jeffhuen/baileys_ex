defmodule BaileysEx.Protocol.BinaryNode do
  @moduledoc """
  Encoder and decoder for WhatsApp's WABinary wire format.

  WABinary is a compact binary encoding of XMPP-style nodes. Each node has a tag
  (string), attributes (string key-value map), and optional content (binary data,
  child nodes, or a string). Strings are compressed via token dictionaries, nibble
  packing, hex packing, or JID-aware encoding.

  The encoded format does NOT include a frame length prefix -- that is handled by
  the connection/Noise layer.
  """

  import Bitwise

  alias BaileysEx.BinaryNode
  alias BaileysEx.Protocol.Constants
  alias BaileysEx.Protocol.JID, as: JIDUtil

  # Tag constants (cached for performance)
  @list_empty 0
  @dictionary_0 236
  @dictionary_3 239
  @interop_jid 245
  @fb_jid 246
  @ad_jid 247
  @list_8 248
  @list_16 249
  @jid_pair 250
  @hex_8 251
  @binary_8 252
  @binary_20 253
  @binary_32 254
  @nibble_8 255
  @packed_max 127

  # ---- Encoding ----

  @doc """
  Encode a `BaileysEx.BinaryNode` to binary.

  The output does not include a frame length prefix. The first byte is always `0`
  (no compression flag), followed by the encoded node.
  """
  @spec encode(BinaryNode.t()) :: binary()
  def encode(%BinaryNode{} = node) do
    IO.iodata_to_binary([<<0>>, encode_node(node)])
  end

  defp encode_node(%BinaryNode{tag: tag, attrs: attrs, content: content}) do
    valid_attrs =
      (attrs || %{})
      |> Enum.filter(fn {_k, v} -> v != nil end)

    num_attrs = length(valid_attrs)
    has_content = content != nil

    list_size = 2 * num_attrs + 1 + if(has_content, do: 1, else: 0)

    [
      write_list_start(list_size),
      write_string(tag),
      Enum.map(valid_attrs, fn {key, value} -> [write_string(key), write_string(value)] end),
      encode_content(content)
    ]
  end

  defp encode_content(nil), do: []

  defp encode_content({:binary, data}) when is_binary(data),
    do: [write_byte_length(byte_size(data)), data]

  defp encode_content(content) when is_binary(content), do: write_string(content)

  defp encode_content(content) when is_list(content) do
    valid_content = Enum.filter(content, &(&1 != nil))
    [write_list_start(length(valid_content)), Enum.map(valid_content, &encode_node/1)]
  end

  defp write_list_start(0), do: <<@list_empty>>
  defp write_list_start(size) when size < 256, do: <<@list_8, size>>

  defp write_list_start(size), do: <<@list_16, size::16-big>>

  @binary_20_threshold bsl(1, 20)

  defp write_byte_length(length) when length >= @binary_20_threshold,
    do: <<@binary_32, length::32-big>>

  defp write_byte_length(length) when length >= 256,
    do: <<@binary_20, length >>> 16 &&& 0x0F, length >>> 8 &&& 0xFF, length &&& 0xFF>>

  defp write_byte_length(length), do: <<@binary_8, length>>

  defp write_string(nil), do: <<@list_empty>>

  defp write_string("") do
    # Empty string is written as raw string with 0 length
    write_string_raw("")
  end

  defp write_string(str) when is_binary(str) do
    case Constants.lookup_token(str) do
      %{dict: dict, index: index} ->
        <<@dictionary_0 + dict, index>>

      %{index: index} ->
        <<index>>

      nil ->
        write_string_non_token(str)
    end
  end

  defp write_string_non_token(str) do
    cond do
      nibble?(str) ->
        write_packed_bytes(str, :nibble)

      hex?(str) ->
        write_packed_bytes(str, :hex)

      true ->
        write_string_jid_or_raw(str)
    end
  end

  defp write_string_jid_or_raw(str) do
    case JIDUtil.parse(str) do
      nil -> write_string_raw(str)
      jid -> write_jid(jid)
    end
  end

  defp write_string_raw(str), do: [write_byte_length(byte_size(str)), str]

  defp write_jid(%BaileysEx.JID{device: device} = jid) when not is_nil(device) do
    domain_type = JIDUtil.domain_type_for_server(jid.server)

    [<<@ad_jid, domain_type, device>>, write_string(jid.user || "")]
  end

  defp write_jid(%BaileysEx.JID{user: user, server: server}) do
    [
      <<@jid_pair>>,
      if(user && user != "", do: write_string(user), else: <<@list_empty>>),
      write_string(server)
    ]
  end

  # Nibble packing: digits, '-', '.'
  defp nibble?(str) when byte_size(str) > @packed_max, do: false
  defp nibble?(""), do: false

  defp nibble?(str) do
    String.to_charlist(str)
    |> Enum.all?(fn c -> (c >= ?0 and c <= ?9) or c == ?- or c == ?. end)
  end

  # Hex packing: digits and A-F
  defp hex?(str) when byte_size(str) > @packed_max, do: false
  defp hex?(""), do: false

  defp hex?(str) do
    String.to_charlist(str)
    |> Enum.all?(fn c -> (c >= ?0 and c <= ?9) or (c >= ?A and c <= ?F) end)
  end

  defp write_packed_bytes(str, type) do
    tag_byte = if type == :nibble, do: @nibble_8, else: @hex_8
    len = String.length(str)
    rounded_length = div(len + 1, 2)

    rounded_length =
      if rem(len, 2) != 0 do
        bor(rounded_length, 128)
      else
        rounded_length
      end

    chars = String.to_charlist(str)
    pack_fn = if type == :nibble, do: &pack_nibble/1, else: &pack_hex/1

    [<<tag_byte, rounded_length>>, pack_char_pairs(chars, pack_fn)]
  end

  defp pack_char_pairs(chars, pack_fn), do: do_pack_char_pairs(chars, pack_fn, [])

  defp do_pack_char_pairs([], _pack_fn, acc), do: Enum.reverse(acc)

  defp do_pack_char_pairs([c1, c2 | rest], pack_fn, acc) do
    byte = bsl(pack_fn.(c1), 4) ||| pack_fn.(c2)
    do_pack_char_pairs(rest, pack_fn, [<<byte>> | acc])
  end

  defp do_pack_char_pairs([c1], pack_fn, acc) do
    byte = bsl(pack_fn.(c1), 4) ||| pack_fn.(0)
    Enum.reverse([<<byte>> | acc])
  end

  defp pack_nibble(c) when c >= ?0 and c <= ?9, do: c - ?0
  defp pack_nibble(?-), do: 10
  defp pack_nibble(?.), do: 11
  defp pack_nibble(0), do: 15

  defp pack_hex(c) when c >= ?0 and c <= ?9, do: c - ?0
  defp pack_hex(c) when c >= ?A and c <= ?F, do: 10 + c - ?A
  defp pack_hex(c) when c >= ?a and c <= ?f, do: 10 + c - ?a
  defp pack_hex(0), do: 15

  # ---- Decoding ----

  @doc """
  Decode binary data into a `BaileysEx.BinaryNode`.

  Expects the raw encoded data (with the leading compression flag byte).
  Handles decompression if the compression bit is set.
  """
  @spec decode(binary()) :: {:ok, BinaryNode.t()} | {:error, term()}
  def decode(data) when is_binary(data) do
    case decompress(data) do
      {:ok, decompressed} ->
        try do
          {node, _rest} = decode_node(decompressed)
          {:ok, node}
        rescue
          e -> {:error, Exception.message(e)}
        end

      {:error, _} = error ->
        error
    end
  end

  defp decompress(<<flag, rest::binary>>) do
    if band(flag, 2) != 0 do
      try do
        {:ok, :zlib.uncompress(rest)}
      rescue
        ErlangError -> {:error, :decompression_failed}
      end
    else
      {:ok, rest}
    end
  end

  defp decompress(<<>>), do: {:error, :empty_data}

  defp decode_node(data) do
    {list_tag, data} = read_byte(data)
    {list_size, data} = consume_list_size(list_tag, data)

    if list_size == 0 do
      raise "invalid node: empty list"
    end

    {header_tag, data} = read_byte(data)
    {header, data} = read_string(header_tag, data)

    if header == "" do
      raise "invalid node: empty header"
    end

    attrs_length = div(list_size - 1, 2)

    {attrs, data} =
      Enum.reduce(1..attrs_length//1, {%{}, data}, fn _, {acc, d} ->
        {key_tag, d} = read_byte(d)
        {key, d} = read_string(key_tag, d)
        {val_tag, d} = read_byte(d)
        {val, d} = read_string(val_tag, d)
        {Map.put(acc, key, val), d}
      end)

    {content, data} = decode_node_content(list_size, data)

    node = %BinaryNode{tag: header, attrs: attrs, content: content}
    {node, data}
  end

  defp decode_node_content(list_size, data) when rem(list_size, 2) != 0, do: {nil, data}

  defp decode_node_content(_list_size, data) do
    {content_tag, data} = read_byte(data)
    decode_content_tag(content_tag, data)
  end

  defp decode_content_tag(content_tag, data)
       when content_tag in [@list_empty, @list_8, @list_16] do
    read_list(content_tag, data)
  end

  defp decode_content_tag(@binary_8, data) do
    {len, data} = read_byte(data)
    <<bytes::binary-size(len), rest::binary>> = data
    {{:binary, bytes}, rest}
  end

  defp decode_content_tag(@binary_20, data) do
    {len, data} = read_int20(data)
    <<bytes::binary-size(len), rest::binary>> = data
    {{:binary, bytes}, rest}
  end

  defp decode_content_tag(@binary_32, <<len::32-big, data::binary>>) do
    <<bytes::binary-size(len), rest::binary>> = data
    {{:binary, bytes}, rest}
  end

  defp decode_content_tag(content_tag, data) do
    read_string(content_tag, data)
  end

  defp read_byte(<<byte, rest::binary>>), do: {byte, rest}
  defp read_byte(<<>>), do: raise("end of stream")

  defp read_int20(<<b1, b2, b3, rest::binary>>) do
    val = bsl(band(b1, 0x0F), 16) + bsl(b2, 8) + b3
    {val, rest}
  end

  defp consume_list_size(@list_empty, data), do: {0, data}
  defp consume_list_size(@list_8, <<size, rest::binary>>), do: {size, rest}
  defp consume_list_size(@list_16, <<size::16-big, rest::binary>>), do: {size, rest}

  # Single-byte token count known at compile time
  @single_byte_token_count tuple_size(Constants.single_byte_tokens())

  defp read_string(tag, data) when tag >= 1 and tag < @single_byte_token_count do
    token = Constants.single_byte_token(tag) || ""
    {token, data}
  end

  defp read_string(tag, data) when tag >= @dictionary_0 and tag <= @dictionary_3 do
    dict = tag - @dictionary_0
    {index, data} = read_byte(data)
    {Constants.double_byte_token(dict, index), data}
  end

  defp read_string(@list_empty, data), do: {"", data}

  defp read_string(@binary_8, data) do
    {len, data} = read_byte(data)
    <<str::binary-size(len), rest::binary>> = data
    {str, rest}
  end

  defp read_string(@binary_20, data) do
    {len, data} = read_int20(data)
    <<str::binary-size(len), rest::binary>> = data
    {str, rest}
  end

  defp read_string(@binary_32, data) do
    <<len::32-big, rest::binary>> = data
    <<str::binary-size(len), rest::binary>> = rest
    {str, rest}
  end

  defp read_string(@jid_pair, data) do
    {user_tag, data} = read_byte(data)
    {user, data} = read_string(user_tag, data)
    {server_tag, data} = read_byte(data)
    {server, data} = read_string(server_tag, data)

    if server != "" do
      user_part = if user == "", do: "", else: user
      {user_part <> "@" <> server, data}
    else
      raise "invalid jid pair: user=#{inspect(user)}, server=#{inspect(server)}"
    end
  end

  defp read_string(@ad_jid, data) do
    {domain_type, data} = read_byte(data)
    {device, data} = read_byte(data)
    {user_tag, data} = read_byte(data)
    {user, data} = read_string(user_tag, data)

    server = JIDUtil.server_from_domain_type(domain_type, "s.whatsapp.net")
    jid_str = JIDUtil.jid_encode(user, server, device)
    {jid_str, data}
  end

  defp read_string(@fb_jid, data) do
    {user_tag, data} = read_byte(data)
    {user, data} = read_string(user_tag, data)
    <<device::16-big, rest::binary>> = data
    {server_tag, rest} = read_byte(rest)
    {server, rest} = read_string(server_tag, rest)
    {"#{user}:#{device}@#{server}", rest}
  end

  defp read_string(@interop_jid, data) do
    {user_tag, data} = read_byte(data)
    {user, data} = read_string(user_tag, data)
    <<device::16-big, integrator::16-big, rest::binary>> = data

    {server, rest} =
      try do
        {server_tag, rest} = read_byte(rest)
        read_string(server_tag, rest)
      rescue
        _ -> {"interop", rest}
      end

    {"#{integrator}-#{user}:#{device}@#{server}", rest}
  end

  defp read_string(@nibble_8, data), do: read_packed8(@nibble_8, data)
  defp read_string(@hex_8, data), do: read_packed8(@hex_8, data)

  defp read_string(tag, _data), do: raise("invalid string with tag: #{tag}")

  defp read_packed8(tag, data) do
    {start_byte, data} = read_byte(data)
    num_bytes = band(start_byte, 127)
    odd = bsr(start_byte, 7) != 0

    {chars, data} =
      Enum.reduce(1..num_bytes//1, {[], data}, fn _, {acc, d} ->
        {byte, d} = read_byte(d)
        high = unpack_byte(tag, bsr(band(byte, 0xF0), 4))
        low = unpack_byte(tag, band(byte, 0x0F))
        {[low, high | acc], d}
      end)

    chars = Enum.reverse(chars)

    value =
      if odd do
        chars |> Enum.slice(0, length(chars) - 1)
      else
        chars
      end

    {List.to_string(value), data}
  end

  defp unpack_byte(@nibble_8, value), do: unpack_nibble(value)
  defp unpack_byte(@hex_8, value), do: unpack_hex(value)

  defp unpack_nibble(v) when v >= 0 and v <= 9, do: ?0 + v
  defp unpack_nibble(10), do: ?-
  defp unpack_nibble(11), do: ?.
  defp unpack_nibble(15), do: 0
  defp unpack_nibble(v), do: raise("invalid nibble: #{v}")

  defp unpack_hex(v) when v >= 0 and v < 10, do: ?0 + v
  defp unpack_hex(v) when v >= 10 and v < 16, do: ?A + v - 10
  defp unpack_hex(v), do: raise("invalid hex: #{v}")

  defp read_list(tag, data) do
    {size, data} = consume_list_size(tag, data)

    {nodes, data} =
      Enum.reduce(1..size//1, {[], data}, fn _, {acc, d} ->
        {node, d} = decode_node(d)
        {[node | acc], d}
      end)

    {Enum.reverse(nodes), data}
  end

  # ---- Generic node helpers ----

  @doc """
  Return all direct child nodes.
  """
  @spec children(BinaryNode.t() | nil) :: [BinaryNode.t()]
  def children(%BinaryNode{content: content}) when is_list(content), do: content
  def children(%BinaryNode{}), do: []
  def children(nil), do: []

  @doc """
  Return all direct child nodes matching the given tag.
  """
  @spec children(BinaryNode.t() | nil, String.t()) :: [BinaryNode.t()]
  def children(node, child_tag) when is_binary(child_tag) do
    Enum.filter(children(node), &(&1.tag == child_tag))
  end

  @doc """
  Return the first direct child node matching the given tag.
  """
  @spec child(BinaryNode.t() | nil, String.t()) :: BinaryNode.t() | nil
  def child(node, child_tag) when is_binary(child_tag) do
    Enum.find(children(node), &(&1.tag == child_tag))
  end

  @doc """
  Return the raw bytes of a child node whose content is explicit binary payload data.
  """
  @spec child_bytes(BinaryNode.t() | nil, String.t()) :: binary() | nil
  def child_bytes(node, child_tag) when is_binary(child_tag) do
    case child(node, child_tag) do
      %BinaryNode{content: {:binary, bytes}} when is_binary(bytes) -> bytes
      _ -> nil
    end
  end

  @doc """
  Return the UTF-8 string content of a child node.

  This accepts either explicit string content or raw bytes that can be interpreted
  as UTF-8, mirroring Baileys' helper behavior.
  """
  @spec child_string(BinaryNode.t() | nil, String.t()) :: String.t() | nil
  def child_string(node, child_tag) when is_binary(child_tag) do
    case child(node, child_tag) do
      %BinaryNode{content: content} when is_binary(content) ->
        content

      %BinaryNode{content: {:binary, bytes}} when is_binary(bytes) ->
        bytes

      _ ->
        nil
    end
  end

  @doc """
  Return `:ok` when the node has no direct `error` child, otherwise return its
  parsed error metadata.
  """
  @spec assert_error_free(BinaryNode.t()) ::
          :ok | {:error, %{code: integer() | nil, text: String.t(), node: BinaryNode.t()}}
  def assert_error_free(%BinaryNode{} = node) do
    case child(node, "error") do
      nil ->
        :ok

      %BinaryNode{} = error_node ->
        {:error,
         %{
           code: parse_int(error_node.attrs["code"]),
           text: error_node.attrs["text"] || "Unknown error",
           node: error_node
         }}
    end
  end

  defp parse_int(nil), do: nil

  defp parse_int(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} -> int
      _ -> nil
    end
  end
end
