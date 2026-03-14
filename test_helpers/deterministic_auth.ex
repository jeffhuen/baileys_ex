defmodule BaileysEx.TestSupport.DeterministicAuth do
  @moduledoc false

  alias BaileysEx.Auth.State
  alias BaileysEx.Crypto
  alias BaileysEx.Signal.Curve

  def state(seed \\ 1, overrides \\ %{}) when is_integer(seed) and is_map(overrides) do
    signed_identity_key = Map.get(overrides, :signed_identity_key, x25519_key_pair(seed + 2))

    signed_pre_key =
      case Map.fetch(overrides, :signed_pre_key) do
        {:ok, signed_pre_key} ->
          signed_pre_key

        :error ->
          {:ok, signed_pre_key} =
            Curve.signed_key_pair(signed_identity_key, seed + 3,
              key_pair: x25519_key_pair(seed + 4)
            )

          signed_pre_key
      end

    state =
      State.new(
        noise_key: Map.get(overrides, :noise_key, x25519_key_pair(seed)),
        pairing_ephemeral_key:
          Map.get(overrides, :pairing_ephemeral_key, x25519_key_pair(seed + 1)),
        signed_identity_key: signed_identity_key,
        signed_pre_key: signed_pre_key,
        registration_id: Map.get(overrides, :registration_id, seed + 1_000),
        adv_secret_key:
          Map.get(overrides, :adv_secret_key, Base.encode64(fixed_bytes(32, seed + 5)))
      )

    Enum.reduce(
      Map.drop(overrides, [
        :noise_key,
        :pairing_ephemeral_key,
        :signed_identity_key,
        :signed_pre_key,
        :registration_id,
        :adv_secret_key
      ]),
      state,
      fn {key, value}, acc -> Map.put(acc, key, value) end
    )
  end

  def x25519_key_pair(seed),
    do: Crypto.generate_key_pair(:x25519, private_key: <<seed::unsigned-big-256>>)

  def fixed_bytes(size, value), do: :binary.copy(<<rem(value, 256)>>, size)
end
