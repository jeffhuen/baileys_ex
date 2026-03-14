defmodule BaileysEx.Native.XEdDSATest do
  use ExUnit.Case, async: true

  alias BaileysEx.Native.XEdDSA

  test "signs and verifies with the pinned sender-key vector" do
    key_pair = %{
      private: Base.decode64!("AAIcmaF2D5rTsgGZo9h4oqGa393qFKjilfMfUDqr8G8="),
      public: Base.decode64!("BYBnBY4toVNm9NPplrAdbCEr09r7ZvolG0erkS7zMnBY") |> binary_part(1, 32)
    }

    message = <<1, 2, 3>>

    expected_signature =
      Base.decode16!(
        "510628a855f33a9cf4d6b3d353d20042d5228c409fed17c5f0121dcc9695c280" <>
          "da292e0fa34a6af9f4dc0aadb3c1637d8c9c313fa6e0bc188d36472e036ea88c",
        case: :mixed
      )

    assert {:ok, signature} = XEdDSA.sign(key_pair.private, message)
    assert signature == expected_signature
    assert XEdDSA.verify(key_pair.public, message, signature)

    refute XEdDSA.verify(key_pair.public, "different", signature)
  end
end
