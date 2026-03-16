defmodule BaileysEx.Util.LTHash do
  @moduledoc """
  Linked Truncated Hash for app state integrity verification.

  LTHash is a summation-based hash that maintains data integrity across a series
  of mutations. Values can be added or removed and the resulting hash equals what
  you'd get from applying the same mutations sequentially.

  The 128-byte hash state is treated as 64 unsigned 16-bit little-endian integers.
  Each value MAC is expanded to 128 bytes via SHA-256 with 4 counter prefixes,
  then added to or subtracted from the state with wrapping arithmetic.

  Ports `LTHashAntiTampering` from Baileys' `whatsapp-rust-bridge` (`lt-hash.ts`).
  """

  import Bitwise

  @hash_size 128
  @num_uint16 64

  @doc """
  Create a fresh 128-byte zero hash state.

  Ports `newLTHashState().hash` — the initial hash is all zeros.
  """
  @spec new() :: <<_::1024>>
  def new, do: <<0::size(@hash_size * 8)>>

  @doc """
  Apply subtract-then-add operations to the hash state.

  First subtracts all `sub_buffs` from the hash, then adds all `add_buffs`.
  Each buffer is a 32-byte value MAC that gets expanded to 128 bytes before
  the arithmetic operation.

  Ports `LT_HASH_ANTI_TAMPERING.subtractThenAdd(hash, subBuffs, addBuffs)`.

  ## Parameters

    * `hash` — 128-byte current hash state
    * `sub_buffs` — list of 32-byte value MACs to subtract
    * `add_buffs` — list of 32-byte value MACs to add

  ## Returns

  Updated 128-byte hash state.
  """
  @spec subtract_then_add(binary(), [binary()], [binary()]) :: binary()
  def subtract_then_add(hash, sub_buffs, add_buffs)
      when byte_size(hash) == @hash_size and is_list(sub_buffs) and is_list(add_buffs) do
    state = decode_uint16s(hash)

    state =
      Enum.reduce(sub_buffs, state, fn buf, acc ->
        expanded = expand(buf)
        subtract_uint16s(acc, expanded)
      end)

    state =
      Enum.reduce(add_buffs, state, fn buf, acc ->
        expanded = expand(buf)
        add_uint16s(acc, expanded)
      end)

    encode_uint16s(state)
  end

  # Expand a 32-byte buffer to 128 bytes using SHA-256 with counter prefixes.
  # SHA-256(0 || buf) || SHA-256(1 || buf) || SHA-256(2 || buf) || SHA-256(3 || buf)
  @spec expand(binary()) :: [non_neg_integer()]
  defp expand(buf) when byte_size(buf) == 32 do
    expanded =
      for i <- 0..3, into: <<>> do
        :crypto.hash(:sha256, <<i::8, buf::binary>>)
      end

    decode_uint16s(expanded)
  end

  # Decode 128 bytes as 64 unsigned 16-bit little-endian integers.
  @spec decode_uint16s(binary()) :: [non_neg_integer()]
  defp decode_uint16s(bin) do
    for <<value::unsigned-little-16 <- bin>>, do: value
  end

  # Encode 64 unsigned 16-bit little-endian integers as 128 bytes.
  @spec encode_uint16s([non_neg_integer()]) :: binary()
  defp encode_uint16s(values) when length(values) == @num_uint16 do
    for value <- values, into: <<>>, do: <<value::unsigned-little-16>>
  end

  # Element-wise uint16 addition with wrapping.
  @spec add_uint16s([non_neg_integer()], [non_neg_integer()]) :: [non_neg_integer()]
  defp add_uint16s(a, b) do
    Enum.zip_with(a, b, fn x, y -> x + y &&& 0xFFFF end)
  end

  # Element-wise uint16 subtraction with wrapping.
  @spec subtract_uint16s([non_neg_integer()], [non_neg_integer()]) :: [non_neg_integer()]
  defp subtract_uint16s(a, b) do
    Enum.zip_with(a, b, fn x, y -> x - y &&& 0xFFFF end)
  end
end
