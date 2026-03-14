defmodule BaileysEx.Protocol.ProtoTest do
  use ExUnit.Case, async: true

  alias BaileysEx.Protocol.Proto.CertChain
  alias BaileysEx.Protocol.Proto.CertChain.NoiseCertificate
  alias BaileysEx.Protocol.Proto.CertChain.NoiseCertificate.Details
  alias BaileysEx.Protocol.Proto.HandshakeMessage
  alias BaileysEx.Protocol.Proto.HandshakeMessage.ClientFinish
  alias BaileysEx.Protocol.Proto.HandshakeMessage.ClientHello
  alias BaileysEx.Protocol.Proto.HandshakeMessage.ServerHello

  test "HandshakeMessage roundtrips client hello fields" do
    message = %HandshakeMessage{
      client_hello: %ClientHello{
        ephemeral: <<1, 2, 3, 4>>,
        static: <<5, 6>>,
        payload: "payload",
        use_extended: true,
        extended_ciphertext: <<7, 8, 9>>
      }
    }

    encoded = HandshakeMessage.encode(message)

    assert {:ok,
            %HandshakeMessage{
              client_hello: %ClientHello{
                ephemeral: <<1, 2, 3, 4>>,
                static: <<5, 6>>,
                payload: "payload",
                use_extended: true,
                extended_ciphertext: <<7, 8, 9>>
              }
            }} = HandshakeMessage.decode(encoded)
  end

  test "HandshakeMessage client hello encoding matches pinned bytes" do
    message = %HandshakeMessage{
      client_hello: %ClientHello{
        ephemeral: <<1, 2, 3, 4>>,
        static: <<5, 6>>,
        payload: "payload",
        use_extended: true,
        extended_ciphertext: <<7, 8, 9>>
      }
    }

    assert Base.decode16!("121A0A0401020304120205061A077061796C6F616420012A03070809",
             case: :mixed
           ) ==
             HandshakeMessage.encode(message)
  end

  test "HandshakeMessage roundtrips server hello and client finish fields" do
    message = %HandshakeMessage{
      server_hello: %ServerHello{
        ephemeral: <<1::256>>,
        static: <<2::384>>,
        payload: <<3, 4, 5>>,
        extended_static: <<6, 7>>
      },
      client_finish: %ClientFinish{
        static: <<8::384>>,
        payload: <<9, 10>>,
        extended_ciphertext: <<11>>
      }
    }

    encoded = HandshakeMessage.encode(message)

    assert {:ok,
            %HandshakeMessage{
              server_hello: %ServerHello{
                ephemeral: <<1::256>>,
                static: <<2::384>>,
                payload: <<3, 4, 5>>,
                extended_static: <<6, 7>>
              },
              client_finish: %ClientFinish{
                static: <<8::384>>,
                payload: <<9, 10>>,
                extended_ciphertext: <<11>>
              }
            }} = HandshakeMessage.decode(encoded)
  end

  test "CertChain roundtrips nested certificate details" do
    details = %Details{
      serial: 10,
      issuer_serial: 9,
      key: <<42::256>>,
      not_before: 1_700_000_000,
      not_after: 1_800_000_000
    }

    details_bin = Details.encode(details)

    chain = %CertChain{
      leaf: %NoiseCertificate{details: details_bin, signature: <<1::512>>},
      intermediate: %NoiseCertificate{details: details_bin, signature: <<2::512>>}
    }

    encoded = CertChain.encode(chain)

    assert {:ok,
            %CertChain{
              leaf: %NoiseCertificate{details: ^details_bin, signature: <<1::512>>},
              intermediate: %NoiseCertificate{details: ^details_bin, signature: <<2::512>>}
            }} = CertChain.decode(encoded)

    assert {:ok,
            %Details{
              serial: 10,
              issuer_serial: 9,
              key: <<42::256>>,
              not_before: 1_700_000_000,
              not_after: 1_800_000_000
            }} = Details.decode(details_bin)
  end
end
