defmodule BaileysEx.Signal.AddressTest do
  use ExUnit.Case, async: true

  alias BaileysEx.Signal.Address

  describe "from_jid/1" do
    test "translates standard WhatsApp JIDs" do
      assert {:ok, %Address{name: "5511999887766", device_id: 0}} =
               Address.from_jid("5511999887766@s.whatsapp.net")

      assert {:ok, %Address{name: "5511999887766", device_id: 0}} =
               Address.from_jid("5511999887766@c.us")
    end

    test "preserves device ID from JID" do
      assert {:ok, %Address{name: "5511999887766", device_id: 2}} =
               Address.from_jid("5511999887766:2@s.whatsapp.net")
    end

    test "encodes LID domain type" do
      assert {:ok, %Address{name: "abc123_1", device_id: 0}} =
               Address.from_jid("abc123@lid")

      assert {:ok, %Address{name: "abc123_1", device_id: 3}} =
               Address.from_jid("abc123:3@lid")
    end

    test "encodes hosted domain type" do
      assert {:ok, %Address{name: "user_128", device_id: 99}} =
               Address.from_jid("user:99@hosted")
    end

    test "encodes hosted.lid domain type" do
      assert {:ok, %Address{name: "user_129", device_id: 99}} =
               Address.from_jid("user:99@hosted.lid")
    end

    test "uses agent field as domain type for standard servers" do
      assert {:ok, %Address{name: "12345_128", device_id: 0}} =
               Address.from_jid("12345_128@s.whatsapp.net")

      assert {:ok, %Address{name: "12345_128", device_id: 3}} =
               Address.from_jid("12345_128:3@s.whatsapp.net")

      assert {:ok, %Address{name: "12345_128", device_id: 0}} =
               Address.from_jid("12345_128@c.us")
    end

    test "rejects device 99 outside hosted domains" do
      assert {:error, :invalid_signal_address} = Address.from_jid("user:99@s.whatsapp.net")
      assert {:error, :invalid_signal_address} = Address.from_jid("user:99@c.us")
      assert {:error, :invalid_signal_address} = Address.from_jid("user:99@lid")
    end

    test "allows device 99 on hosted domains" do
      assert {:ok, %Address{device_id: 99}} = Address.from_jid("user:99@hosted")
      assert {:ok, %Address{device_id: 99}} = Address.from_jid("user:99@hosted.lid")
    end

    test "rejects JIDs with unknown servers" do
      assert {:error, :invalid_signal_address} = Address.from_jid("user@g.us")
      assert {:error, :invalid_signal_address} = Address.from_jid("user@broadcast")
      assert {:error, :invalid_signal_address} = Address.from_jid("user@newsletter")
      assert {:error, :invalid_signal_address} = Address.from_jid("user@unknown.server")
    end

    test "rejects JIDs without @ separator" do
      assert {:error, :invalid_signal_address} = Address.from_jid("no-at-sign")
    end

    test "rejects JIDs without a user part" do
      assert {:error, :invalid_signal_address} = Address.from_jid("@s.whatsapp.net")
    end

    test "rejects non-binary input" do
      assert {:error, :invalid_signal_address} = Address.from_jid(nil)
      assert {:error, :invalid_signal_address} = Address.from_jid(123)
    end
  end

  describe "to_string/1" do
    test "formats as name.device_id" do
      assert "user.0" == Address.to_string(%Address{name: "user", device_id: 0})
      assert "user_1.3" == Address.to_string(%Address{name: "user_1", device_id: 3})
    end
  end

  describe "String.Chars protocol" do
    test "converts address to string via interpolation" do
      address = %Address{name: "user", device_id: 0}
      assert "user.0" == "#{address}"
    end
  end
end
