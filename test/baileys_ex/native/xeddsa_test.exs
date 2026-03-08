defmodule BaileysEx.Native.XEdDSATest do
  use ExUnit.Case, async: true

  alias BaileysEx.Crypto
  alias BaileysEx.Native.XEdDSA

  test "signs and verifies with x25519 keys" do
    key_pair = Crypto.generate_key_pair(:x25519)
    message = "noise certificate payload"

    assert {:ok, signature} = XEdDSA.sign(key_pair.private, message)
    assert byte_size(signature) == 64
    assert XEdDSA.verify(key_pair.public, message, signature)

    refute XEdDSA.verify(key_pair.public, "different", signature)
  end
end
