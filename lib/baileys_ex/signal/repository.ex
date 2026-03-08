defmodule BaileysEx.Signal.Repository do
  @moduledoc """
  Public Signal repository boundary used by later connection and messaging phases.

  This module owns JID-to-Signal address translation, session bundle normalization,
  and the Elixir-facing return contracts. The cryptographic/session engine stays
  behind the adapter boundary so Phase 5 can grow without committing to an
  oversized native surface.
  """

  alias BaileysEx.Signal.Address
  alias BaileysEx.Signal.Curve

  @typedoc "Injected peer session bundle used to bootstrap an outgoing session."
  @type e2e_session :: %{
          registration_id: non_neg_integer(),
          identity_key: binary(),
          signed_pre_key: %{
            key_id: non_neg_integer(),
            public_key: binary(),
            signature: binary()
          },
          pre_key: %{
            key_id: non_neg_integer(),
            public_key: binary()
          }
        }

  @typedoc "Repository result for `validate_session/2`."
  @type session_status ::
          %{exists: true}
          | %{exists: false, reason: :no_session | :no_open_session | :validation_error}

  @type adapter_error ::
          :invalid_ciphertext
          | :invalid_session
          | :invalid_signal_address
          | :no_session
          | term()

  @type t :: %__MODULE__{
          adapter: module(),
          adapter_state: term(),
          lid_mapping: term()
        }

  defmodule Adapter do
    @moduledoc false

    alias BaileysEx.Signal.Address
    alias BaileysEx.Signal.Repository

    @type validation_result :: :exists | :no_session | :no_open_session | :validation_error

    @callback inject_e2e_session(term(), Address.t(), Repository.e2e_session()) ::
                {:ok, term()} | {:error, term()}

    @callback validate_session(term(), Address.t()) ::
                {:ok, validation_result()} | {:error, term()}

    @callback encrypt_message(term(), Address.t(), binary()) ::
                {:ok, term(), %{type: :pkmsg | :msg, ciphertext: binary()}} | {:error, term()}

    @callback decrypt_message(term(), Address.t(), :pkmsg | :msg, binary()) ::
                {:ok, term(), binary()} | {:error, term()}

    @callback delete_sessions(term(), [Address.t()]) ::
                {:ok, term()} | {:error, term()}

    @spec session_key(Address.t()) :: String.t()
    def session_key(%Address{} = address), do: Address.to_string(address)
  end

  @enforce_keys [:adapter]
  defstruct [:adapter, adapter_state: %{}, lid_mapping: nil]

  @spec new(keyword()) :: t()
  def new(opts) do
    %__MODULE__{
      adapter: Keyword.fetch!(opts, :adapter),
      adapter_state: Keyword.get(opts, :adapter_state, %{}),
      lid_mapping: Keyword.get(opts, :lid_mapping)
    }
  end

  @spec jid_to_signal_protocol_address(String.t()) ::
          {:ok, String.t()} | {:error, :invalid_signal_address}
  def jid_to_signal_protocol_address(jid) do
    with {:ok, address} <- Address.from_jid(jid) do
      {:ok, Address.to_string(address)}
    end
  end

  @spec inject_e2e_session(t(), %{jid: String.t(), session: e2e_session()}) ::
          {:ok, t()} | {:error, adapter_error()}
  def inject_e2e_session(%__MODULE__{} = repository, %{jid: jid, session: session}) do
    with {:ok, address} <- Address.from_jid(jid),
         {:ok, session} <- normalize_session(session),
         {:ok, adapter_state} <-
           repository.adapter.inject_e2e_session(repository.adapter_state, address, session) do
      {:ok, %{repository | adapter_state: adapter_state}}
    end
  end

  def inject_e2e_session(%__MODULE__{}, _opts), do: {:error, :invalid_session}

  @spec validate_session(t(), String.t()) :: {:ok, session_status()} | {:error, adapter_error()}
  def validate_session(%__MODULE__{} = repository, jid) do
    with {:ok, address} <- Address.from_jid(jid),
         {:ok, validation} <-
           repository.adapter.validate_session(repository.adapter_state, address) do
      {:ok, normalize_validation(validation)}
    end
  end

  @spec encrypt_message(t(), %{jid: String.t(), data: binary()}) ::
          {:ok, t(), %{type: :pkmsg | :msg, ciphertext: binary()}} | {:error, adapter_error()}
  def encrypt_message(%__MODULE__{} = repository, %{jid: jid, data: data}) when is_binary(data) do
    with {:ok, address} <- Address.from_jid(jid),
         {:ok, adapter_state, encrypted} <-
           repository.adapter.encrypt_message(repository.adapter_state, address, data) do
      {:ok, %{repository | adapter_state: adapter_state}, encrypted}
    end
  end

  def encrypt_message(%__MODULE__{}, _opts), do: {:error, :invalid_session}

  @spec decrypt_message(t(), %{jid: String.t(), type: :pkmsg | :msg, ciphertext: binary()}) ::
          {:ok, t(), binary()} | {:error, adapter_error()}
  def decrypt_message(%__MODULE__{} = repository, %{jid: jid, type: type, ciphertext: ciphertext})
      when type in [:pkmsg, :msg] and is_binary(ciphertext) do
    with {:ok, address} <- Address.from_jid(jid),
         {:ok, adapter_state, plaintext} <-
           repository.adapter.decrypt_message(repository.adapter_state, address, type, ciphertext) do
      {:ok, %{repository | adapter_state: adapter_state}, plaintext}
    end
  end

  def decrypt_message(%__MODULE__{}, _opts), do: {:error, :invalid_ciphertext}

  @spec delete_session(t(), [String.t()]) :: {:ok, t()} | {:error, adapter_error()}
  def delete_session(%__MODULE__{} = repository, jids) when is_list(jids) do
    with {:ok, addresses} <- normalize_addresses(jids),
         {:ok, adapter_state} <-
           repository.adapter.delete_sessions(repository.adapter_state, addresses) do
      {:ok, %{repository | adapter_state: adapter_state}}
    end
  end

  def delete_session(%__MODULE__{}, _jids), do: {:error, :invalid_signal_address}

  @spec normalize_addresses([String.t()]) ::
          {:ok, [Address.t()]} | {:error, :invalid_signal_address}
  defp normalize_addresses(jids) do
    Enum.reduce_while(jids, {:ok, []}, fn jid, {:ok, addresses} ->
      case Address.from_jid(jid) do
        {:ok, address} -> {:cont, {:ok, [address | addresses]}}
        {:error, :invalid_signal_address} -> {:halt, {:error, :invalid_signal_address}}
      end
    end)
    |> reverse_ok_list()
  end

  @spec reverse_ok_list({:ok, [term()]} | {:error, term()}) :: {:ok, [term()]} | {:error, term()}
  defp reverse_ok_list({:ok, values}), do: {:ok, Enum.reverse(values)}
  defp reverse_ok_list({:error, _} = error), do: error

  @spec normalize_validation(Adapter.validation_result()) :: session_status()
  defp normalize_validation(:exists), do: %{exists: true}
  defp normalize_validation(:no_session), do: %{exists: false, reason: :no_session}
  defp normalize_validation(:no_open_session), do: %{exists: false, reason: :no_open_session}
  defp normalize_validation(:validation_error), do: %{exists: false, reason: :validation_error}

  @spec normalize_session(map()) :: {:ok, e2e_session()} | {:error, :invalid_session}
  defp normalize_session(%{
         registration_id: registration_id,
         identity_key: identity_key,
         signed_pre_key: %{key_id: signed_key_id, public_key: signed_key, signature: signature},
         pre_key: %{key_id: pre_key_id, public_key: pre_key}
       })
       when is_integer(registration_id) and registration_id >= 0 and
              is_integer(signed_key_id) and signed_key_id >= 0 and
              is_integer(pre_key_id) and pre_key_id >= 0 and
              is_binary(signature) and byte_size(signature) == 64 do
    with {:ok, identity_key} <- Curve.generate_signal_pub_key(identity_key),
         {:ok, signed_key} <- Curve.generate_signal_pub_key(signed_key),
         {:ok, pre_key} <- Curve.generate_signal_pub_key(pre_key) do
      {:ok,
       %{
         registration_id: registration_id,
         identity_key: identity_key,
         signed_pre_key: %{key_id: signed_key_id, public_key: signed_key, signature: signature},
         pre_key: %{key_id: pre_key_id, public_key: pre_key}
       }}
    else
      {:error, :invalid_public_key} -> {:error, :invalid_session}
    end
  end

  defp normalize_session(_session), do: {:error, :invalid_session}
end
