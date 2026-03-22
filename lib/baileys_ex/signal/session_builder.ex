defmodule BaileysEx.Signal.SessionBuilder do
  @moduledoc false

  alias BaileysEx.Crypto
  alias BaileysEx.Signal.Curve
  alias BaileysEx.Signal.SessionRecord

  @discontinuity :binary.copy(<<0xFF>>, 32)
  @whisper_text "WhisperText"
  @whisper_ratchet "WhisperRatchet"
  @zero_salt <<0::256>>

  @doc """
  Initialize an outgoing session (Alice side of X3DH).

  Requires Bob's pre-key bundle:
    - `identity_key` — Bob's identity public key (33-byte Signal format)
    - `signed_pre_key` — Bob's signed pre-key public key (33-byte Signal format)
    - `pre_key` — Bob's one-time pre-key public key (33-byte Signal format, optional)
    - `registration_id` — Bob's registration ID
    - `signed_pre_key_id` — Bob's signed pre-key ID
    - `pre_key_id` — Bob's one-time pre-key ID (optional)

  Returns `{:ok, updated_record, base_key_pair}`.
  """
  @spec init_outgoing(SessionRecord.t(), map(), keyword()) ::
          {:ok, SessionRecord.t(), %{public: binary(), private: binary()}} | {:error, term()}
  def init_outgoing(%SessionRecord{} = record, bundle, opts \\ []) do
    their_identity_key = bundle.identity_key
    their_signed_pre_key = bundle.signed_pre_key
    their_pre_key = Map.get(bundle, :pre_key)
    registration_id = bundle.registration_id
    signed_pre_key_id = bundle.signed_pre_key_id
    pre_key_id = Map.get(bundle, :pre_key_id)

    our_identity_key = Keyword.fetch!(opts, :identity_key_pair)

    base_key_pair =
      opts
      |> Keyword.get_lazy(:base_key_pair, &Curve.generate_key_pair/0)
      |> Curve.ensure_signal_key_pair!()

    with {:ok, shared_secret} <-
           compute_alice_shared_secret(
             our_identity_key,
             base_key_pair,
             their_identity_key,
             their_signed_pre_key,
             their_pre_key
           ),
         {:ok, derived} <- Crypto.hkdf(shared_secret, @whisper_text, 64, @zero_salt) do
      <<root_key::binary-32, _chain_key::binary-32>> = derived

      # Alice immediately calculates a sending ratchet
      sending_ratchet_pair =
        opts
        |> Keyword.get_lazy(:sending_ratchet_pair, &Curve.generate_key_pair/0)
        |> Curve.ensure_signal_key_pair!()

      {:ok, sending_secret} = Curve.shared_key(sending_ratchet_pair.private, their_signed_pre_key)
      {:ok, sending_derived} = Crypto.hkdf(sending_secret, @whisper_ratchet, 64, root_key)
      <<new_root_key::binary-32, sending_chain_key::binary-32>> = sending_derived

      {:ok, our_identity_signal} = Curve.generate_signal_pub_key(our_identity_key.public)
      {:ok, their_identity_signal} = Curve.generate_signal_pub_key(their_identity_key)

      session = %{
        current_ratchet: %{
          root_key: new_root_key,
          ephemeral_key_pair: sending_ratchet_pair,
          last_remote_ephemeral: Curve.ensure_signal_public_key!(their_signed_pre_key),
          previous_counter: 0
        },
        index_info: %{
          remote_identity_key: their_identity_signal,
          local_identity_key: our_identity_signal,
          base_key: base_key_pair.public,
          base_key_type: :sending,
          closed: nil
        },
        chains:
          put_chain(%{}, sending_ratchet_pair.public, %{
            chain_key: %{counter: 0, key: sending_chain_key},
            chain_type: :sending,
            message_keys: %{}
          }),
        pending_pre_key: %{
          pre_key_id: pre_key_id,
          signed_pre_key_id: signed_pre_key_id,
          base_key: base_key_pair.public
        },
        registration_id: registration_id
      }

      record =
        record
        |> SessionRecord.close_open_session()
        |> SessionRecord.put_session(base_key_pair.public, session)

      {:ok, record, base_key_pair}
    end
  end

  @doc """
  Initialize an incoming session (Bob side of X3DH).

  Called when receiving a PreKeyWhisperMessage from Alice.
  """
  @spec init_incoming(SessionRecord.t(), map(), map(), keyword()) ::
          {:ok, SessionRecord.t()} | {:error, term()}
  def init_incoming(%SessionRecord{} = record, their_message, our_keys, opts \\ []) do
    their_identity_key = their_message.identity_key
    their_base_key = their_message.base_key

    if SessionRecord.get_session(record, their_base_key) do
      {:ok, record}
    else
      do_init_incoming(record, their_identity_key, their_base_key, our_keys, opts)
    end
  end

  defp do_init_incoming(record, their_identity_key, their_base_key, our_keys, opts) do
    our_identity_key = Keyword.fetch!(opts, :identity_key_pair)
    our_signed_pre_key = our_keys.signed_pre_key |> Curve.ensure_signal_key_pair!()
    our_pre_key = our_keys |> Map.get(:pre_key) |> maybe_ensure_signal_key_pair()
    registration_id = Keyword.get(opts, :registration_id, 0)
    their_base_key = Curve.ensure_signal_public_key!(their_base_key)

    with {:ok, shared_secret} <-
           compute_bob_shared_secret(
             our_identity_key,
             our_signed_pre_key,
             our_pre_key,
             their_identity_key,
             their_base_key
           ),
         {:ok, derived} <- Crypto.hkdf(shared_secret, @whisper_text, 64, @zero_salt) do
      <<root_key::binary-32, _chain_key::binary-32>> = derived

      {:ok, their_identity_signal} = Curve.generate_signal_pub_key(their_identity_key)
      {:ok, our_identity_signal} = Curve.generate_signal_pub_key(our_identity_key.public)

      session = %{
        current_ratchet: %{
          root_key: root_key,
          ephemeral_key_pair: our_signed_pre_key,
          last_remote_ephemeral: their_base_key,
          previous_counter: 0
        },
        index_info: %{
          remote_identity_key: their_identity_signal,
          local_identity_key: our_identity_signal,
          base_key: their_base_key,
          base_key_type: :receiving,
          closed: nil
        },
        chains: %{},
        pending_pre_key: nil,
        registration_id: registration_id
      }

      record =
        record
        |> SessionRecord.close_open_session()
        |> SessionRecord.put_session(their_base_key, session)

      {:ok, record}
    end
  end

  # Alice: DH1=DH(IK_A, SPK_B), DH2=DH(EK_A, IK_B), DH3=DH(EK_A, SPK_B), [DH4=DH(EK_A, OPK_B)]
  defp compute_alice_shared_secret(
         our_identity_key,
         base_key_pair,
         their_identity_key,
         their_signed_pre_key,
         their_pre_key
       ) do
    with {:ok, dh1} <- Curve.shared_key(our_identity_key.private, their_signed_pre_key),
         {:ok, dh2} <- Curve.shared_key(base_key_pair.private, their_identity_key),
         {:ok, dh3} <- Curve.shared_key(base_key_pair.private, their_signed_pre_key) do
      shared = @discontinuity <> dh1 <> dh2 <> dh3

      shared =
        if their_pre_key do
          {:ok, dh4} = Curve.shared_key(base_key_pair.private, their_pre_key)
          shared <> dh4
        else
          shared
        end

      {:ok, shared}
    end
  end

  # Bob: DH1=DH(SPK_B, IK_A), DH2=DH(IK_B, EK_A), DH3=DH(SPK_B, EK_A), [DH4=DH(OPK_B, EK_A)]
  defp compute_bob_shared_secret(
         our_identity_key,
         our_signed_pre_key,
         our_pre_key,
         their_identity_key,
         their_base_key
       ) do
    with {:ok, dh1} <- Curve.shared_key(our_signed_pre_key.private, their_identity_key),
         {:ok, dh2} <- Curve.shared_key(our_identity_key.private, their_base_key),
         {:ok, dh3} <- Curve.shared_key(our_signed_pre_key.private, their_base_key) do
      shared = @discontinuity <> dh1 <> dh2 <> dh3

      shared =
        if our_pre_key do
          {:ok, dh4} = Curve.shared_key(our_pre_key.private, their_base_key)
          shared <> dh4
        else
          shared
        end

      {:ok, shared}
    end
  end

  defp put_chain(chains, public_key, chain) do
    Map.put(chains, Base.encode64(public_key), chain)
  end

  defp maybe_ensure_signal_key_pair(nil), do: nil
  defp maybe_ensure_signal_key_pair(key_pair), do: Curve.ensure_signal_key_pair!(key_pair)
end
