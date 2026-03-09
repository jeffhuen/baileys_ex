defmodule BaileysEx.Signal.Identity do
  @moduledoc """
  In-memory Signal identity store with TOFU and change detection semantics.

  Identity keys are stored by canonical Signal address string. Raw 32-byte public
  keys are normalized to the Signal-prefixed 33-byte form before comparison.
  """

  alias BaileysEx.Signal.Address
  alias BaileysEx.Signal.Curve

  @type save_result :: :new | :unchanged | :changed

  @type t :: %__MODULE__{
          entries: %{optional(String.t()) => binary()}
        }

  @type error :: :invalid_identity_key

  defstruct entries: %{}

  @spec new() :: t()
  def new, do: %__MODULE__{}

  @spec load(t(), Address.t()) :: {:ok, binary() | nil}
  def load(%__MODULE__{} = identity_store, %Address{} = address) do
    {:ok, Map.get(identity_store.entries, Address.to_string(address))}
  end

  @spec save(t(), Address.t(), binary()) :: {:ok, t(), save_result()} | {:error, error()}
  def save(%__MODULE__{} = identity_store, %Address{} = address, identity_key)
      when is_binary(identity_key) do
    with {:ok, identity_key} <- normalize_identity_key(identity_key) do
      address_key = Address.to_string(address)
      persist_identity(identity_store, address_key, identity_key)
    end
  end

  def save(%__MODULE__{}, %Address{}, _identity_key), do: {:error, :invalid_identity_key}

  defp normalize_identity_key(identity_key) do
    case Curve.generate_signal_pub_key(identity_key) do
      {:ok, prefixed_identity_key} -> {:ok, prefixed_identity_key}
      {:error, :invalid_public_key} -> {:error, :invalid_identity_key}
    end
  end

  defp persist_identity(identity_store, address_key, identity_key) do
    case Map.fetch(identity_store.entries, address_key) do
      :error ->
        {:ok, put_identity(identity_store, address_key, identity_key), :new}

      {:ok, ^identity_key} ->
        {:ok, identity_store, :unchanged}

      {:ok, _existing_identity_key} ->
        {:ok, put_identity(identity_store, address_key, identity_key), :changed}
    end
  end

  defp put_identity(identity_store, address_key, identity_key) do
    %{identity_store | entries: Map.put(identity_store.entries, address_key, identity_key)}
  end
end
