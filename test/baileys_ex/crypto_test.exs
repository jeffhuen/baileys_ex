defmodule BaileysEx.CryptoTest do
  use ExUnit.Case, async: true

  alias BaileysEx.Crypto

  # ============================================================================
  # HKDF — RFC 5869 Test Vectors (SHA-256)
  # ============================================================================

  describe "hkdf/4" do
    test "RFC 5869 Test Case 1" do
      ikm = Base.decode16!("0B0B0B0B0B0B0B0B0B0B0B0B0B0B0B0B0B0B0B0B0B0B")
      salt = Base.decode16!("000102030405060708090A0B0C")
      info = Base.decode16!("F0F1F2F3F4F5F6F7F8F9")
      length = 42

      expected_prk =
        Base.decode16!("077709362C2E32DF0DDC3F0DC47BBA6390B6C73BB50F9C3122EC844AD7C2B3E5")

      expected_okm =
        Base.decode16!(
          "3CB25F25FAACD57A90434F64D0362F2A2D2D0A90CF1A5A4C5DB02D56ECC4C5BF34007208D5B887185865"
        )

      # Verify extract step independently
      prk = Crypto.hkdf_extract(salt, ikm)
      assert prk == expected_prk

      # Verify expand step independently
      okm = Crypto.hkdf_expand(prk, info, length)
      assert okm == expected_okm

      # Verify combined hkdf
      assert {:ok, ^expected_okm} = Crypto.hkdf(ikm, info, length, salt)
    end

    test "RFC 5869 Test Case 2 — longer inputs/outputs" do
      ikm =
        Base.decode16!(
          "000102030405060708090A0B0C0D0E0F101112131415161718191A1B1C1D1E1F" <>
            "202122232425262728292A2B2C2D2E2F303132333435363738393A3B3C3D3E3F" <>
            "404142434445464748494A4B4C4D4E4F"
        )

      salt =
        Base.decode16!(
          "606162636465666768696A6B6C6D6E6F707172737475767778797A7B7C7D7E7F" <>
            "808182838485868788898A8B8C8D8E8F909192939495969798999A9B9C9D9E9F" <>
            "A0A1A2A3A4A5A6A7A8A9AAABACADAEAF"
        )

      info =
        Base.decode16!(
          "B0B1B2B3B4B5B6B7B8B9BABBBCBDBEBFC0C1C2C3C4C5C6C7C8C9CACBCCCDCECF" <>
            "D0D1D2D3D4D5D6D7D8D9DADBDCDDDEDFE0E1E2E3E4E5E6E7E8E9EAEBECEDEEEF" <>
            "F0F1F2F3F4F5F6F7F8F9FAFBFCFDFEFF"
        )

      length = 82

      expected_prk =
        Base.decode16!("06A6B88C5853361A06104C9CEB35B45CEF760014904671014A193F40C15FC244")

      expected_okm =
        Base.decode16!(
          "B11E398DC80327A1C8E7F78C596A49344F012EDA2D4EFAD8A050CC4C19AFA97C" <>
            "59045A99CAC7827271CB41C65E590E09DA3275600C2F09B8367793A9ACA3DB71" <>
            "CC30C58179EC3E87C14C01D5C1F3434F1D87"
        )

      prk = Crypto.hkdf_extract(salt, ikm)
      assert prk == expected_prk

      assert {:ok, ^expected_okm} = Crypto.hkdf(ikm, info, length, salt)
    end

    test "RFC 5869 Test Case 3 — zero-length salt and info" do
      ikm = Base.decode16!("0B0B0B0B0B0B0B0B0B0B0B0B0B0B0B0B0B0B0B0B0B0B")
      salt = <<>>
      info = <<>>
      length = 42

      expected_prk =
        Base.decode16!("19EF24A32C717B167F33A91D6F648BDF96596776AFDB6377AC434C1C293CCB04")

      expected_okm =
        Base.decode16!(
          "8DA4E775A563C18F715F802A063C5A31B8A11F5C5EE1879EC3454E5F3C738D2D9D201395FAA4B61A96C8"
        )

      prk = Crypto.hkdf_extract(salt, ikm)
      assert prk == expected_prk

      assert {:ok, ^expected_okm} = Crypto.hkdf(ikm, info, length, salt)
    end
  end

  # ============================================================================
  # AES-256-GCM — NIST Test Vector
  # ============================================================================

  describe "aes_gcm_encrypt/4 and aes_gcm_decrypt/4" do
    test "NIST AES-256-GCM test vector" do
      # NIST SP 800-38D Test Case 16 (256-bit key)
      key = Base.decode16!("FEFFE9928665731C6D6A8F9467308308FEFFE9928665731C6D6A8F9467308308")
      iv = Base.decode16!("CAFEBABEFACEDBADDECAF888")

      plaintext =
        Base.decode16!(
          "D9313225F88406E5A55909C5AFF5269A86A7A9531534F7DA2E4C303D8A318A721C3C0C95956809532FCF0E2449A6B525B16AEDF5AA0DE657BA637B39"
        )

      aad = Base.decode16!("FEEDFACEDEADBEEFFEEDFACEDEADBEEFABADDAD2")

      expected_ciphertext =
        Base.decode16!(
          "522DC1F099567D07F47F37A32A84427D643A8CDCBFE5C0C97598A2BD2555D1AA8CB08E48590DBB3DA7B08B1056828838C5F61E6393BA7A0ABCC9F662"
        )

      expected_tag = Base.decode16!("76FC6ECE0F4E1768CDDF8853BB2D551B")

      {:ok, result} = Crypto.aes_gcm_encrypt(key, iv, plaintext, aad)
      assert result == expected_ciphertext <> expected_tag

      {:ok, decrypted} = Crypto.aes_gcm_decrypt(key, iv, result, aad)
      assert decrypted == plaintext
    end

    test "decrypt fails with wrong key" do
      key = fixed_bytes(32, 1)
      wrong_key = fixed_bytes(32, 2)
      iv = fixed_bytes(12, 3)
      plaintext = "hello world"

      {:ok, ciphertext} = Crypto.aes_gcm_encrypt(key, iv, plaintext)
      assert {:error, :decrypt_failed} = Crypto.aes_gcm_decrypt(wrong_key, iv, ciphertext)
    end

    test "decrypt fails with tampered ciphertext" do
      key = fixed_bytes(32, 4)
      iv = fixed_bytes(12, 5)
      plaintext = "hello world"

      {:ok, ciphertext} = Crypto.aes_gcm_encrypt(key, iv, plaintext)

      # Flip a bit in the ciphertext portion
      <<first_byte, rest::binary>> = ciphertext
      tampered = <<Bitwise.bxor(first_byte, 1), rest::binary>>
      assert {:error, :decrypt_failed} = Crypto.aes_gcm_decrypt(key, iv, tampered)
    end
  end

  # ============================================================================
  # AES-256-CBC — roundtrip with known plaintext
  # ============================================================================

  describe "aes_cbc_encrypt/3 and aes_cbc_decrypt/3" do
    test "roundtrip with block-aligned plaintext (16 bytes)" do
      key = fixed_bytes(32, 6)
      iv = fixed_bytes(16, 7)
      plaintext = "exactly16bytes!!"

      assert byte_size(plaintext) == 16
      {:ok, ciphertext} = Crypto.aes_cbc_encrypt(key, iv, plaintext)
      # PKCS7 adds a full block when input is block-aligned
      assert byte_size(ciphertext) == 32
      {:ok, decrypted} = Crypto.aes_cbc_decrypt(key, iv, ciphertext)
      assert decrypted == plaintext
    end

    test "roundtrip with non-aligned plaintext" do
      key = fixed_bytes(32, 8)
      iv = fixed_bytes(16, 9)
      plaintext = "hello"

      {:ok, ciphertext} = Crypto.aes_cbc_encrypt(key, iv, plaintext)
      assert byte_size(ciphertext) == 16
      {:ok, decrypted} = Crypto.aes_cbc_decrypt(key, iv, ciphertext)
      assert decrypted == plaintext
    end

    test "roundtrip with empty plaintext" do
      key = fixed_bytes(32, 10)
      iv = fixed_bytes(16, 11)
      plaintext = <<>>

      {:ok, ciphertext} = Crypto.aes_cbc_encrypt(key, iv, plaintext)
      assert byte_size(ciphertext) == 16
      {:ok, decrypted} = Crypto.aes_cbc_decrypt(key, iv, ciphertext)
      assert decrypted == plaintext
    end

    test "NIST AES-256-CBC test vector" do
      # NIST SP 800-38A F.2.5 CBC-AES256.Encrypt
      key = Base.decode16!("603DEB1015CA71BE2B73AEF0857D77811F352C073B6108D72D9810A30914DFF4")
      iv = Base.decode16!("000102030405060708090A0B0C0D0E0F")
      plaintext = Base.decode16!("6BC1BEE22E409F96E93D7E117393172A")

      expected_ciphertext = Base.decode16!("F58C4C04D6E5F1BA779EABFB5F7BFBD6")

      # For this test, manually encrypt without PKCS7 to match NIST vector
      # (NIST vectors don't use PKCS7 padding)
      raw_ciphertext =
        :crypto.crypto_one_time(:aes_256_cbc, key, iv, plaintext, encrypt: true)

      assert raw_ciphertext == expected_ciphertext
    end

    test "module API produces a pinned PKCS7 CBC ciphertext" do
      key = Base.decode16!("603DEB1015CA71BE2B73AEF0857D77811F352C073B6108D72D9810A30914DFF4")
      iv = Base.decode16!("000102030405060708090A0B0C0D0E0F")
      plaintext = "hello"

      expected_ciphertext = Base.decode16!("11567E234FD4575F682CE39DEF007307")

      assert {:ok, ^expected_ciphertext} = Crypto.aes_cbc_encrypt(key, iv, plaintext)
      assert {:ok, ^plaintext} = Crypto.aes_cbc_decrypt(key, iv, expected_ciphertext)
    end
  end

  # ============================================================================
  # AES-256-CTR
  # ============================================================================

  describe "aes_ctr_encrypt/3 and aes_ctr_decrypt/3" do
    test "matches the NIST AES-256-CTR vector through the module API" do
      key = Base.decode16!("603DEB1015CA71BE2B73AEF0857D77811F352C073B6108D72D9810A30914DFF4")
      iv = Base.decode16!("F0F1F2F3F4F5F6F7F8F9FAFBFCFDFEFF")

      plaintext =
        Base.decode16!(
          "6BC1BEE22E409F96E93D7E117393172A" <>
            "AE2D8A571E03AC9C9EB76FAC45AF8E51" <>
            "30C81C46A35CE411E5FBC1191A0A52EF" <>
            "F69F2445DF4F9B17AD2B417BE66C3710"
        )

      expected_ciphertext =
        Base.decode16!(
          "601EC313775789A5B7A7F504BBF3D228" <>
            "F443E3CA4D62B59ACA84E990CACAF5C5" <>
            "2B0930DAA23DE94CE87017BA2D84988D" <>
            "DFC9C58DB67AADA613C2DD08457941A6"
        )

      assert {:ok, ^expected_ciphertext} = Crypto.aes_ctr_encrypt(key, iv, plaintext)
      assert {:ok, ^plaintext} = Crypto.aes_ctr_decrypt(key, iv, expected_ciphertext)
    end

    test "roundtrip" do
      key = fixed_bytes(32, 12)
      iv = fixed_bytes(16, 13)
      plaintext = "stream cipher roundtrip test data"

      {:ok, ciphertext} = Crypto.aes_ctr_encrypt(key, iv, plaintext)
      assert ciphertext != plaintext
      assert byte_size(ciphertext) == byte_size(plaintext)
      {:ok, decrypted} = Crypto.aes_ctr_decrypt(key, iv, ciphertext)
      assert decrypted == plaintext
    end

    test "ciphertext has same length as plaintext (stream cipher)" do
      key = fixed_bytes(32, 14)
      iv = fixed_bytes(16, 15)

      for len <- [0, 1, 7, 15, 16, 17, 31, 32, 33, 100] do
        plaintext = fixed_bytes(len, 16 + len)
        {:ok, ciphertext} = Crypto.aes_ctr_encrypt(key, iv, plaintext)
        assert byte_size(ciphertext) == len
      end
    end
  end

  # ============================================================================
  # HMAC — RFC 4231 Test Vectors
  # ============================================================================

  describe "hmac_sha256/2" do
    test "RFC 4231 Test Case 1" do
      key = Base.decode16!("0B0B0B0B0B0B0B0B0B0B0B0B0B0B0B0B0B0B0B0B")
      data = "Hi There"

      expected =
        Base.decode16!("B0344C61D8DB38535CA8AFCEAF0BF12B881DC200C9833DA726E9376C2E32CFF7")

      assert Crypto.hmac_sha256(key, data) == expected
    end

    test "RFC 4231 Test Case 2" do
      key = "Jefe"
      data = "what do ya want for nothing?"

      expected =
        Base.decode16!("5BDCC146BF60754E6A042426089575C75A003F089D2739839DEC58B964EC3843")

      assert Crypto.hmac_sha256(key, data) == expected
    end

    test "RFC 4231 Test Case 3" do
      key = Base.decode16!("AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA")

      data =
        Base.decode16!(
          "DDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDD"
        )

      expected =
        Base.decode16!("773EA91E36800E46854DB8EBD09181A72959098B3EF8C122D9635514CED565FE")

      assert Crypto.hmac_sha256(key, data) == expected
    end
  end

  describe "hmac_sha512/2" do
    test "RFC 4231 Test Case 1" do
      key = Base.decode16!("0B0B0B0B0B0B0B0B0B0B0B0B0B0B0B0B0B0B0B0B")
      data = "Hi There"

      expected =
        Base.decode16!(
          "87AA7CDEA5EF619D4FF0B4241A1D6CB02379F4E2CE4EC2787AD0B30545E17CDE" <>
            "DAA833B7D6B8A702038B274EAEA3F4E4BE9D914EEB61F1702E696C203A126854"
        )

      assert Crypto.hmac_sha512(key, data) == expected
    end
  end

  # ============================================================================
  # SHA-256 / MD5
  # ============================================================================

  describe "sha256/1" do
    test "known value" do
      assert Crypto.sha256("") ==
               Base.decode16!("E3B0C44298FC1C149AFBF4C8996FB92427AE41E4649B934CA495991B7852B855")

      assert Crypto.sha256("hello") ==
               Base.decode16!("2CF24DBA5FB0A30E26E83B2AC5B9E29E1B161E5C1FA7425E73043362938B9824")
    end
  end

  describe "md5/1" do
    test "known value" do
      assert Crypto.md5("") == Base.decode16!("D41D8CD98F00B204E9800998ECF8427E")
      assert Crypto.md5("hello") == Base.decode16!("5D41402ABC4B2A76B9719D911017C592")
    end
  end

  # ============================================================================
  # Curve25519 — RFC 7748 Test Vector
  # ============================================================================

  describe "Curve25519 key exchange" do
    test "RFC 7748 test vector" do
      # RFC 7748 Section 6.1 — Curve25519 test vector
      alice_private =
        Base.decode16!("77076D0A7318A57D3C16C17251B26645DF4C2F87EBC0992AB177FBA51DB92C2A")

      alice_public =
        Base.decode16!("8520F0098930A754748B7DDCB43EF75A0DBF3A0D26381AF4EBA4A98EAA9B4E6A")

      bob_private =
        Base.decode16!("5DAB087E624A8A4B79E17F8B83800EE66F3BB1292618B6FD1C2F8B27FF88E0EB")

      bob_public =
        Base.decode16!("DE9EDB7D7B7DC1B4D35B61C2ECE435373F8343C85B78674DADFC7E146F882B4F")

      expected_shared =
        Base.decode16!("4A5D9D5BA4CE2DE1728E3BF480350F25E07E21C947D19E3376F09B3C1E161742")

      # Verify public key derivation
      {derived_alice_public, _} = :crypto.generate_key(:ecdh, :x25519, alice_private)
      assert derived_alice_public == alice_public

      {derived_bob_public, _} = :crypto.generate_key(:ecdh, :x25519, bob_private)
      assert derived_bob_public == bob_public

      # Verify shared secret (both directions)
      {:ok, shared_ab} = Crypto.shared_secret(alice_private, bob_public)
      assert shared_ab == expected_shared

      {:ok, shared_ba} = Crypto.shared_secret(bob_private, alice_public)
      assert shared_ba == expected_shared
    end

    test "generate_key_pair produces 32-byte keys" do
      pair = Crypto.generate_key_pair(:x25519, private_key: <<29::256>>)
      assert byte_size(pair.public) == 32
      assert byte_size(pair.private) == 32
    end

    test "generate_key_pair accepts a fixed x25519 private key" do
      private_key =
        Base.decode16!("77076D0A7318A57D3C16C17251B26645DF4C2F87EBC0992AB177FBA51DB92C2A")

      expected_public =
        Base.decode16!("8520F0098930A754748B7DDCB43EF75A0DBF3A0D26381AF4EBA4A98EAA9B4E6A")

      assert %{public: ^expected_public, private: ^private_key} =
               Crypto.generate_key_pair(:x25519, private_key: private_key)
    end
  end

  # ============================================================================
  # Ed25519 — roundtrip sign/verify
  # ============================================================================

  describe "Ed25519 sign/verify" do
    test "roundtrip sign and verify" do
      pair = Crypto.generate_key_pair(:ed25519, private_key: <<30::256>>)
      message = "test message for signing"

      signature = Crypto.ed25519_sign(pair.private, message)
      assert byte_size(signature) == 64
      assert Crypto.ed25519_verify(pair.public, message, signature)
    end

    test "verify fails with wrong public key" do
      pair1 = Crypto.generate_key_pair(:ed25519, private_key: <<31::256>>)
      pair2 = Crypto.generate_key_pair(:ed25519, private_key: <<32::256>>)
      message = "test message"

      signature = Crypto.ed25519_sign(pair1.private, message)
      refute Crypto.ed25519_verify(pair2.public, message, signature)
    end

    test "verify fails with tampered message" do
      pair = Crypto.generate_key_pair(:ed25519, private_key: <<33::256>>)
      message = "original message"

      signature = Crypto.ed25519_sign(pair.private, message)
      refute Crypto.ed25519_verify(pair.public, "tampered message", signature)
    end

    test "RFC 8032 test vector 1 — empty message" do
      # RFC 8032 Section 7.1 Test Vector 1
      seed =
        Base.decode16!("9D61B19DEFFD5A60BA844AF492EC2CC44449C5697B326919703BAC031CAE7F60")

      message = <<>>

      expected_signature =
        Base.decode16!(
          "E5564300C360AC729086E2CC806E828A84877F1EB8E5D974D873E06522490155" <>
            "5FB8821590A33BACC61E39701CF9B46BD25BF5F0595BBE24655141438E7A100B"
        )

      # OTP's Ed25519 key derivation may differ from RFC 8032's published
      # public key, but signing produces the correct RFC signature.
      # Derive the public key via OTP for verification.
      {public_key, _} = :crypto.generate_key(:eddsa, :ed25519, seed)

      signature = Crypto.ed25519_sign(seed, message)
      assert signature == expected_signature
      assert Crypto.ed25519_verify(public_key, message, signature)
    end

    test "generate_key_pair accepts a fixed ed25519 private key" do
      private_key =
        Base.decode16!("9D61B19DEFFD5A60BA844AF492EC2CC44449C5697B326919703BAC031CAE7F60")

      {expected_public, _} = :crypto.generate_key(:eddsa, :ed25519, private_key)

      assert %{public: ^expected_public, private: ^private_key} =
               Crypto.generate_key_pair(:ed25519, private_key: private_key)
    end
  end

  # ============================================================================
  # Media key expansion
  # ============================================================================

  describe "expand_media_key/2" do
    test "matches the pinned image media key vector" do
      media_key =
        Base.decode16!("000102030405060708090A0B0C0D0E0F101112131415161718191A1B1C1D1E1F")

      expected = %{
        iv: Base.decode16!("AA6A127218397CBD2383E4CCF7176A79"),
        cipher_key:
          Base.decode16!("008C9AEA9B7C5D81EB56B3F530F87D42DCC92D27B11AD6B5BD66F0560D0D8C46"),
        mac_key:
          Base.decode16!("91D09FFEC108833C1699574C52657923FB6E3E161D9698BC6B3A05FBC508A515"),
        ref_key:
          Base.decode16!("4D4981725E9EB39838FCFF2130508F1360CBB319F99CEF163D57AB7C050A667E")
      }

      assert Crypto.expand_media_key(media_key, :image) == expected
    end

    test "produces 112 bytes split correctly" do
      media_key = fixed_bytes(32, 34)

      for media_type <- [:image, :video, :audio, :document, :sticker] do
        result = Crypto.expand_media_key(media_key, media_type)

        assert byte_size(result.iv) == 16
        assert byte_size(result.cipher_key) == 32
        assert byte_size(result.mac_key) == 32
        assert byte_size(result.ref_key) == 32
      end
    end

    test "different media types produce different keys" do
      media_key = fixed_bytes(32, 36)
      image_keys = Crypto.expand_media_key(media_key, :image)
      video_keys = Crypto.expand_media_key(media_key, :video)
      assert image_keys != video_keys
    end

    test "sticker uses same info string as image" do
      media_key = fixed_bytes(32, 37)
      image_keys = Crypto.expand_media_key(media_key, :image)
      sticker_keys = Crypto.expand_media_key(media_key, :sticker)
      assert image_keys == sticker_keys
    end

    test "gif uses same info string as video" do
      media_key = fixed_bytes(32, 38)
      video_keys = Crypto.expand_media_key(media_key, :video)
      gif_keys = Crypto.expand_media_key(media_key, :gif)
      assert video_keys == gif_keys
    end

    test "all extended media types produce valid output" do
      media_key = fixed_bytes(32, 39)

      all_types = [
        :image,
        :video,
        :audio,
        :document,
        :sticker,
        :gif,
        :ptt,
        :ptv,
        :product,
        :thumbnail_document,
        :thumbnail_image,
        :thumbnail_video,
        :thumbnail_link,
        :md_msg_hist,
        :md_app_state,
        :product_catalog_image,
        :payment_bg_image,
        :ppic,
        :biz_cover_photo
      ]

      for media_type <- all_types do
        result = Crypto.expand_media_key(media_key, media_type)

        total =
          byte_size(result.iv) + byte_size(result.cipher_key) + byte_size(result.mac_key) +
            byte_size(result.ref_key)

        assert total == 112, "media type #{media_type} should produce 112 bytes total"
      end
    end
  end

  # ============================================================================
  # PKCS7 padding
  # ============================================================================

  describe "pkcs7_pad/2 and pkcs7_unpad/2" do
    test "pads non-aligned data" do
      padded = Crypto.pkcs7_pad("hello", 16)
      assert byte_size(padded) == 16
      assert binary_part(padded, 5, 11) == :binary.copy(<<11>>, 11)
    end

    test "pads block-aligned data with full block" do
      data = :binary.copy(<<0>>, 16)
      padded = Crypto.pkcs7_pad(data, 16)
      assert byte_size(padded) == 32
      assert binary_part(padded, 16, 16) == :binary.copy(<<16>>, 16)
    end

    test "pads empty data" do
      padded = Crypto.pkcs7_pad(<<>>, 16)
      assert byte_size(padded) == 16
      assert padded == :binary.copy(<<16>>, 16)
    end

    test "unpad recovers original data" do
      original = "test data"
      padded = Crypto.pkcs7_pad(original, 16)
      assert {:ok, ^original} = Crypto.pkcs7_unpad(padded, 16)
    end

    test "unpad rejects invalid padding" do
      # Wrong padding value
      invalid = <<1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 3>>
      assert {:error, :invalid_padding} = Crypto.pkcs7_unpad(invalid, 16)
    end

    test "unpad rejects empty data" do
      assert {:error, :invalid_padding} = Crypto.pkcs7_unpad(<<>>, 16)
    end

    test "unpad rejects non-block-aligned data" do
      assert {:error, :invalid_padding} = Crypto.pkcs7_unpad(<<1, 2, 3>>, 16)
    end

    test "roundtrip with various sizes" do
      for size <- [0, 1, 2, 7, 8, 15, 16, 17, 31, 32, 33, 255] do
        data = fixed_bytes(size, size)
        padded = Crypto.pkcs7_pad(data, 16)
        assert rem(byte_size(padded), 16) == 0
        assert byte_size(padded) > byte_size(data)
        assert {:ok, ^data} = Crypto.pkcs7_unpad(padded, 16)
      end
    end
  end

  # ============================================================================
  # PBKDF2
  # ============================================================================

  describe "pbkdf2_sha256/4" do
    test "RFC 6070 test vector 1" do
      password = "password"
      salt = "salt"
      iterations = 1
      dk_len = 32

      expected =
        Base.decode16!("120FB6CFFCF8B32C43E7225256C4F837A86548C92CCC35480805987CB70BE17B")

      assert {:ok, ^expected} = Crypto.pbkdf2_sha256(password, salt, iterations, dk_len)
    end

    test "RFC 6070 test vector 2" do
      password = "password"
      salt = "salt"
      iterations = 2
      dk_len = 32

      expected =
        Base.decode16!("AE4D0C95AF6B46D32D0ADFF928F06DD02A303F8EF3C251DFD6E2D85A95474C43")

      assert {:ok, ^expected} = Crypto.pbkdf2_sha256(password, salt, iterations, dk_len)
    end

    test "RFC 6070 test vector 3" do
      password = "password"
      salt = "salt"
      iterations = 4096
      dk_len = 32

      expected =
        Base.decode16!("C5E478D59288C841AA530DB6845C4C8D962893A001CE4E11A4963873AA98134A")

      assert {:ok, ^expected} = Crypto.pbkdf2_sha256(password, salt, iterations, dk_len)
    end
  end

  # ============================================================================
  # Random bytes
  # ============================================================================

  describe "random_bytes/1" do
    test "returns requested number of bytes" do
      for n <- [0, 1, 16, 32, 64, 256] do
        result = Crypto.random_bytes(n)
        assert byte_size(result) == n
      end
    end
  end

  defp fixed_bytes(0, _value), do: <<>>
  defp fixed_bytes(size, value), do: :binary.copy(<<rem(value, 256)>>, size)
end
