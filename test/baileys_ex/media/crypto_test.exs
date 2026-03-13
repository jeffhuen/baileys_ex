defmodule BaileysEx.Media.CryptoTest do
  use ExUnit.Case, async: true

  alias BaileysEx.Media.Crypto

  @tag :tmp_dir
  test "encrypt/3 and decrypt/3 roundtrip image media with deterministic metadata", %{
    tmp_dir: tmp_dir
  } do
    plaintext = String.duplicate("hello media", 9)
    media_key = :binary.copy(<<7>>, 32)
    expected_length = byte_size(plaintext)

    assert {:ok,
            %{
              encrypted_path: encrypted_path,
              media_key: ^media_key,
              file_sha256: file_sha256,
              file_enc_sha256: file_enc_sha256,
              file_length: ^expected_length
            }} =
             Crypto.encrypt(plaintext, :image,
               media_key: media_key,
               tmp_dir: tmp_dir
             )

    encrypted = File.read!(encrypted_path)

    assert file_sha256 == :crypto.hash(:sha256, plaintext)
    assert file_enc_sha256 == :crypto.hash(:sha256, encrypted)
    assert {:ok, ^plaintext} = Crypto.decrypt(encrypted, media_key, :image)
  end

  @tag :tmp_dir
  test "encrypt/3 accepts file streams and decrypt/3 rejects tampered MACs", %{tmp_dir: tmp_dir} do
    media_key = :binary.copy(<<9>>, 32)
    plaintext = String.duplicate("streamed payload", 8)
    plain_path = Path.join(tmp_dir, "plain.bin")
    File.write!(plain_path, plaintext)

    assert {:ok, %{encrypted_path: encrypted_path}} =
             Crypto.encrypt(File.stream!(plain_path, [], 17), :audio,
               media_key: media_key,
               tmp_dir: tmp_dir
             )

    encrypted = File.read!(encrypted_path)
    <<prefix::binary-size(byte_size(encrypted) - 1), last>> = encrypted
    tampered = prefix <> <<Bitwise.bxor(last, 0xFF)>>

    assert {:error, :mac_mismatch} = Crypto.decrypt(tampered, media_key, :audio)
  end

  test "decrypt/3 rejects payloads without room for ciphertext and mac" do
    assert {:error, :invalid_media_payload} =
             Crypto.decrypt(<<1, 2, 3>>, :binary.copy(<<1>>, 32), :image)
  end
end
