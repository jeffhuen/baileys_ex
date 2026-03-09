defmodule BaileysEx.Signal.Identity do
  @moduledoc """
  Store-backed Signal identity helpers with TOFU and change detection semantics.

  Identity keys are stored by canonical Signal address string in the
  `:"identity-key"` family. Raw 32-byte public keys are normalized to the
  Signal-prefixed 33-byte form before comparison and persistence.
  """

  alias BaileysEx.Signal.Address
  alias BaileysEx.Signal.Curve
  alias BaileysEx.Signal.Store

  @type save_result :: :new | :unchanged | :changed
  @type error :: :invalid_identity_key

  @spec load(Store.t(), Address.t()) :: {:ok, binary() | nil}
  def load(%Store{} = store, %Address{} = address) do
    address_key = Address.to_string(address)
    {:ok, Map.get(Store.get(store, :"identity-key", [address_key]), address_key)}
  end

  @spec save(Store.t(), Address.t(), binary()) :: {:ok, save_result()} | {:error, error()}
  def save(%Store{} = store, %Address{} = address, identity_key) when is_binary(identity_key) do
    with {:ok, normalized_identity_key} <- normalize_identity_key(identity_key) do
      address_key = Address.to_string(address)

      result =
        Store.transaction(store, "identity-key:#{address_key}", fn ->
          persist_identity(store, address_key, normalized_identity_key)
        end)

      {:ok, result}
    end
  end

  def save(%Store{}, %Address{}, _identity_key), do: {:error, :invalid_identity_key}

  defp normalize_identity_key(identity_key) do
    case Curve.generate_signal_pub_key(identity_key) do
      {:ok, prefixed_identity_key} -> {:ok, prefixed_identity_key}
      {:error, :invalid_public_key} -> {:error, :invalid_identity_key}
    end
  end

  defp persist_identity(store, address_key, identity_key) do
    case Store.get(store, :"identity-key", [address_key]) do
      %{^address_key => ^identity_key} ->
        :unchanged

      %{^address_key => _existing_identity_key} ->
        :ok = Store.set(store, %{:"identity-key" => %{address_key => identity_key}})
        :changed

      %{} ->
        :ok = Store.set(store, %{:"identity-key" => %{address_key => identity_key}})
        :new
    end
  end
end
