defmodule BaileysEx.Signal.Curve do
  @moduledoc """
  Signal-specific Curve25519 helpers matching the Baileys Curve contract.

  This module keeps the native surface narrow by delegating X25519 agreement to
  `BaileysEx.Crypto` and XEdDSA signing/verification to `BaileysEx.Native.XEdDSA`.
  """

  alias BaileysEx.Crypto
  alias BaileysEx.Native.XEdDSA

  @signal_key_prefix 5

  @type key_pair :: Crypto.key_pair()
  @type signed_key_pair :: %{
          key_pair: key_pair(),
          signature: binary(),
          key_id: non_neg_integer()
        }
  @type key_error :: :invalid_private_key | :invalid_public_key | :invalid_identity_key

  @doc """
  Generate a Curve25519 key pair for Signal session and pre-key usage.
  """
  @spec generate_key_pair(keyword()) :: key_pair()
  def generate_key_pair(opts \\ []), do: Crypto.generate_key_pair(:x25519, opts)

  @doc """
  Derive a shared X25519 secret from a private key and peer public key.

  Accepts either raw 32-byte public keys or the 33-byte Signal-prefixed form.
  """
  @spec shared_key(binary(), binary()) :: {:ok, binary()} | {:error, key_error()}
  def shared_key(private_key, public_key) do
    with {:ok, private_key} <- normalize_private_key(private_key),
         {:ok, public_key} <- normalize_public_key(public_key) do
      Crypto.shared_secret(private_key, public_key)
    end
  end

  @doc """
  Prefix a 32-byte public key with the Signal version byte.

  Already-prefixed keys are returned unchanged.
  """
  @spec generate_signal_pub_key(binary()) :: {:ok, binary()} | {:error, :invalid_public_key}
  def generate_signal_pub_key(<<@signal_key_prefix, public_key::binary-size(32)>>) do
    {:ok, <<@signal_key_prefix, public_key::binary>>}
  end

  def generate_signal_pub_key(<<public_key::binary-size(32)>>) do
    {:ok, <<@signal_key_prefix, public_key::binary>>}
  end

  def generate_signal_pub_key(_public_key), do: {:error, :invalid_public_key}

  @doc false
  @spec ensure_signal_key_pair!(key_pair()) :: key_pair()
  def ensure_signal_key_pair!(%{public: public_key} = key_pair) do
    {:ok, signal_public_key} = generate_signal_pub_key(public_key)
    %{key_pair | public: signal_public_key}
  end

  @doc false
  @spec ensure_signal_public_key!(binary()) :: binary()
  def ensure_signal_public_key!(public_key) do
    {:ok, signal_public_key} = generate_signal_pub_key(public_key)
    signal_public_key
  end

  @doc """
  Sign a payload with a Curve25519 private key using XEdDSA.
  """
  @spec sign(binary(), binary()) :: {:ok, binary()} | {:error, :invalid_private_key}
  def sign(private_key, message) do
    with {:ok, private_key} <- normalize_private_key(private_key) do
      XEdDSA.sign(private_key, message)
    end
  end

  @doc """
  Verify a XEdDSA signature against either a raw or Signal-prefixed public key.
  """
  @spec verify(binary(), binary(), binary()) :: boolean()
  def verify(public_key, message, signature) do
    case normalize_public_key(public_key) do
      {:ok, public_key} -> XEdDSA.verify(public_key, message, signature)
      {:error, :invalid_public_key} -> false
    end
  end

  @doc """
  Generate a signed pre-key payload matching Baileys `signedKeyPair`.
  """
  @spec signed_key_pair(map(), non_neg_integer(), keyword()) ::
          {:ok, signed_key_pair()} | {:error, key_error()}
  def signed_key_pair(identity_key_pair, key_id, opts \\ [])

  def signed_key_pair(%{private: private_key}, key_id, opts)
      when is_integer(key_id) and key_id >= 0 and is_list(opts) do
    key_pair =
      Keyword.get(opts, :key_pair) || generate_key_pair(Keyword.get(opts, :key_pair_opts, []))

    with {:ok, private_key} <- normalize_private_key(private_key),
         {:ok, signal_public_key} <- generate_signal_pub_key(key_pair.public),
         {:ok, signature} <- sign(private_key, signal_public_key) do
      {:ok, %{key_pair: key_pair, signature: signature, key_id: key_id}}
    end
  end

  def signed_key_pair(_identity_key_pair, _key_id, _opts), do: {:error, :invalid_identity_key}

  @spec normalize_private_key(binary()) :: {:ok, binary()} | {:error, :invalid_private_key}
  defp normalize_private_key(<<private_key::binary-size(32)>>), do: {:ok, private_key}
  defp normalize_private_key(_private_key), do: {:error, :invalid_private_key}

  @spec normalize_public_key(binary()) :: {:ok, binary()} | {:error, :invalid_public_key}
  defp normalize_public_key(<<@signal_key_prefix, public_key::binary-size(32)>>),
    do: {:ok, public_key}

  defp normalize_public_key(<<public_key::binary-size(32)>>), do: {:ok, public_key}
  defp normalize_public_key(_public_key), do: {:error, :invalid_public_key}
end
