defmodule BaileysEx.Media.CrossValidationTest do
  use ExUnit.Case, async: true

  alias BaileysEx.Crypto, as: CoreCrypto
  alias BaileysEx.Media.Crypto

  @fixture_path Path.expand("../../fixtures/media/baileys_v7.json", __DIR__)

  @tag :tmp_dir
  test "matches the committed Baileys rc.9 image media fixture", %{tmp_dir: tmp_dir} do
    fixture = fixture!()["image"]
    plaintext = decode64!(fixture["plaintext"])
    media_key = decode64!(fixture["media_key"])
    expected_iv = decode64!(fixture["iv"])
    expected_cipher_key = decode64!(fixture["cipher_key"])
    expected_mac_key = decode64!(fixture["mac_key"])
    expected_encrypted = decode64!(fixture["encrypted"])
    expected_file_sha256 = decode64!(fixture["file_sha256"])
    expected_file_enc_sha256 = decode64!(fixture["file_enc_sha256"])

    assert %{
             iv: ^expected_iv,
             cipher_key: ^expected_cipher_key,
             mac_key: ^expected_mac_key
           } = CoreCrypto.expand_media_key(media_key, :image)

    assert {:ok,
            %{
              encrypted_path: encrypted_path,
              media_key: ^media_key,
              file_sha256: ^expected_file_sha256,
              file_enc_sha256: ^expected_file_enc_sha256,
              file_length: 32
            }} =
             Crypto.encrypt(plaintext, :image,
               media_key: media_key,
               tmp_dir: tmp_dir
             )

    assert File.read!(encrypted_path) == expected_encrypted
    assert {:ok, ^plaintext} = Crypto.decrypt(expected_encrypted, media_key, :image)
  end

  defp fixture! do
    @fixture_path
    |> File.read!()
    |> JSON.decode!()
  end

  defp decode64!(value), do: Base.decode64!(value)
end
