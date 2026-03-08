defmodule BaileysEx.Native.NoiseTest do
  use ExUnit.Case, async: true

  alias BaileysEx.Native.Noise
  alias BaileysEx.Protocol.Noise, as: ProtocolNoise

  @wa_header ProtocolNoise.noise_header()

  test "multiple raw Noise sessions handshake independently in parallel" do
    results =
      1..8
      |> Task.async_stream(
        fn index ->
          {initiator, responder} = complete_raw_handshake()

          outbound = "initiator-#{index}"
          inbound = "responder-#{index}"

          ciphertext1 = Noise.encrypt(initiator, outbound)
          plaintext1 = Noise.decrypt(responder, ciphertext1)

          ciphertext2 = Noise.encrypt(responder, inbound)
          plaintext2 = Noise.decrypt(initiator, ciphertext2)

          {plaintext1, plaintext2}
        end,
        max_concurrency: 8,
        ordered: false,
        timeout: 5_000
      )
      |> Enum.to_list()

    assert Enum.all?(results, &match?({:ok, {_outbound, _inbound}}, &1))

    roundtrips =
      Enum.map(results, fn {:ok, payloads} -> payloads end)
      |> MapSet.new()

    assert MapSet.size(roundtrips) == 8
  end

  test "raw Noise resources can be repeatedly created, used, and dropped without crashing" do
    for _ <- 1..100 do
      {initiator, responder} = complete_raw_handshake()

      ciphertext = Noise.encrypt(initiator, "payload")
      assert Noise.decrypt(responder, ciphertext) == "payload"
    end

    # Smoke-test resource teardown; this is not a proof of leak freedom.
    :erlang.garbage_collect(self())
    assert true
  end

  defp complete_raw_handshake do
    initiator = Noise.init(@wa_header)
    responder = Noise.init_responder(@wa_header)

    msg1 = Noise.handshake_write(initiator, <<>>)
    _ = Noise.handshake_read(responder, msg1)

    msg2 = Noise.handshake_write(responder, "server-payload")
    assert Noise.handshake_read(initiator, msg2) == "server-payload"

    msg3 = Noise.handshake_write(initiator, "client-payload")
    assert Noise.handshake_read(responder, msg3) == "client-payload"

    assert :ok = Noise.finish(initiator)
    assert :ok = Noise.finish(responder)

    {initiator, responder}
  end
end
