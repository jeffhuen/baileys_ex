defmodule BaileysEx.Native.NoiseTest do
  # async: false — the ResourceArc leak-detection test asserts on a global
  # Rust atomic counter (LIVE_SESSION_COUNT). Other async test modules that
  # create Noise sessions pollute the baseline, causing intermittent failures.
  # Do not change to async: true without removing or isolating that test.
  use ExUnit.Case, async: false

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

    :erlang.garbage_collect(self())
    assert true
  end

  test "NoiseSession ResourceArc resources are freed when references are dropped" do
    # Record baseline — other tests may have live sessions
    :erlang.garbage_collect(self())
    baseline = Noise.session_count()

    # Create sessions in a spawned process so they become unreachable on exit
    test_pid = self()

    pid =
      spawn(fn ->
        sessions =
          for _ <- 1..20 do
            {i, r} = complete_raw_handshake()
            {i, r}
          end

        send(test_pid, {:created, length(sessions) * 2})
      end)

    ref = Process.monitor(pid)
    assert_receive {:created, 40}, 5_000
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 5_000

    # Force GC on ourselves (shouldn't matter — sessions were in the spawned process)
    :erlang.garbage_collect(self())

    # The spawned process is dead; its heap has been freed. The BEAM's resource
    # destructor calls Rust Drop, decrementing the atomic counter.
    # Allow a small window for the destructor to run.
    final_count =
      Enum.reduce_while(1..50, nil, fn _, _ ->
        count = Noise.session_count()

        if count <= baseline do
          {:halt, count}
        else
          Process.sleep(10)
          {:cont, count}
        end
      end)

    assert final_count <= baseline,
           "expected session count to return to #{baseline}, got #{Noise.session_count()}"
  end

  test "fixed private keys produce pinned handshake messages" do
    initiator =
      Noise.init(@wa_header, private_key: <<1::256>>, ephemeral_private_key: <<3::256>>)

    responder =
      Noise.init_responder(@wa_header, private_key: <<2::256>>, ephemeral_private_key: <<4::256>>)

    msg1 = Noise.handshake_write(initiator, <<>>)

    assert Base.decode16!(
             "9952FB7E5383C522C954DE94F2E4620D3E08CD9E7248AD23207F9EF55C904144",
             case: :mixed
           ) == msg1

    assert Noise.handshake_read(responder, msg1) == <<>>

    msg2 = Noise.handshake_write(responder, "server-payload")

    assert Base.decode16!(
             "EC13D23A17DAF174750DF7AD67A86A1D4EABEC8F517636605281C1DB18C66649" <>
               "C2F0F9CB372084D28245BF139E4438D999A6151D15EE77E60ADFE3D952A48BAB" <>
               "37FA7B1F53760482CEB93D94E91B9E965CBEEC403BC0DFBCC4AEA65526ABD284" <>
               "315B259D606332D3416161AE5CFE",
             case: :mixed
           ) == msg2

    assert Noise.handshake_read(initiator, msg2) == "server-payload"
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
