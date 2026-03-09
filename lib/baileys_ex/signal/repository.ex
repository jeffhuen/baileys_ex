defmodule BaileysEx.Signal.Repository do
  @moduledoc """
  Public Signal repository boundary for connection and messaging consumers.

  This module owns JID-to-Signal address translation, session bundle normalization,
  and the Elixir-facing return contracts. The cryptographic and session engine stays
  behind an adapter boundary, keeping the native surface minimal.
  """

  alias BaileysEx.Signal.Address
  alias BaileysEx.Signal.Curve
  alias BaileysEx.Signal.Group.SenderKeyName
  alias BaileysEx.Signal.LIDMappingStore

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
          | :no_sender_key_state
          | :no_session
          | term()

  @type migration_operation :: %{
          from: Address.t(),
          to: Address.t(),
          pn_user: String.t(),
          lid_user: String.t(),
          device_id: non_neg_integer()
        }

  @type migration_result :: %{
          migrated: non_neg_integer(),
          skipped: non_neg_integer(),
          total: non_neg_integer()
        }

  @type t :: %__MODULE__{
          adapter: module(),
          adapter_state: term(),
          lid_mapping: LIDMappingStore.t()
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

    @callback get_device_list(term(), String.t()) ::
                {:ok, term(), [String.t()] | nil} | {:error, term()}

    @callback migrate_sessions(term(), [Repository.migration_operation()]) ::
                {:ok, term(), Repository.migration_result()} | {:error, term()}

    @callback encrypt_group_message(term(), SenderKeyName.t(), binary()) ::
                {:ok, term(), %{ciphertext: binary(), sender_key_distribution_message: binary()}}
                | {:error, term()}

    @callback process_sender_key_distribution_message(term(), SenderKeyName.t(), binary()) ::
                {:ok, term()} | {:error, term()}

    @callback decrypt_group_message(term(), SenderKeyName.t(), binary()) ::
                {:ok, term(), binary()} | {:error, term()}

    @spec session_key(Address.t()) :: String.t()
    def session_key(%Address{} = address), do: Address.to_string(address)
  end

  @enforce_keys [:adapter]
  defstruct [:adapter, adapter_state: %{}, lid_mapping: LIDMappingStore.new()]

  @spec new(keyword()) :: t()
  def new(opts) do
    %__MODULE__{
      adapter: Keyword.fetch!(opts, :adapter),
      adapter_state: Keyword.get(opts, :adapter_state, %{}),
      lid_mapping: Keyword.get(opts, :lid_mapping, LIDMappingStore.new())
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

  @spec encrypt_group_message(t(), %{group: String.t(), me_id: String.t(), data: binary()}) ::
          {:ok, t(), %{ciphertext: binary(), sender_key_distribution_message: binary()}}
          | {:error, adapter_error()}
  def encrypt_group_message(%__MODULE__{} = repository, %{group: group, me_id: me_id, data: data})
      when is_binary(group) and is_binary(me_id) and is_binary(data) do
    with {:ok, sender_key_name} <- sender_key_name(group, me_id),
         {:ok, adapter_state, encrypted} <-
           repository.adapter.encrypt_group_message(
             repository.adapter_state,
             sender_key_name,
             data
           ) do
      {:ok, %{repository | adapter_state: adapter_state}, encrypted}
    end
  end

  def encrypt_group_message(%__MODULE__{}, _opts), do: {:error, :invalid_signal_address}

  @spec process_sender_key_distribution_message(
          t(),
          %{
            author_jid: String.t(),
            item: %{group_id: String.t(), axolotl_sender_key_distribution_message: binary()}
          }
        ) :: {:ok, t()} | {:error, adapter_error()}
  def process_sender_key_distribution_message(
        %__MODULE__{} = repository,
        %{
          author_jid: author_jid,
          item: %{
            group_id: group_id,
            axolotl_sender_key_distribution_message: distribution_message
          }
        }
      )
      when is_binary(author_jid) and is_binary(group_id) and is_binary(distribution_message) do
    with {:ok, sender_key_name} <- sender_key_name(group_id, author_jid),
         {:ok, adapter_state} <-
           repository.adapter.process_sender_key_distribution_message(
             repository.adapter_state,
             sender_key_name,
             distribution_message
           ) do
      {:ok, %{repository | adapter_state: adapter_state}}
    end
  end

  def process_sender_key_distribution_message(%__MODULE__{}, _opts),
    do: {:error, :invalid_signal_address}

  @spec decrypt_group_message(t(), %{group: String.t(), author_jid: String.t(), msg: binary()}) ::
          {:ok, t(), binary()} | {:error, adapter_error()}
  def decrypt_group_message(%__MODULE__{} = repository, %{
        group: group,
        author_jid: author_jid,
        msg: msg
      })
      when is_binary(group) and is_binary(author_jid) and is_binary(msg) do
    with {:ok, sender_key_name} <- sender_key_name(group, author_jid),
         {:ok, adapter_state, plaintext} <-
           repository.adapter.decrypt_group_message(
             repository.adapter_state,
             sender_key_name,
             msg
           ) do
      {:ok, %{repository | adapter_state: adapter_state}, plaintext}
    end
  end

  def decrypt_group_message(%__MODULE__{}, _opts), do: {:error, :invalid_signal_address}

  @spec store_lid_pn_mappings(t(), [LIDMappingStore.mapping()]) ::
          {:ok, t()} | {:error, LIDMappingStore.error()}
  def store_lid_pn_mappings(%__MODULE__{} = repository, mappings) do
    with {:ok, lid_mapping} <-
           LIDMappingStore.store_lid_pn_mappings(repository.lid_mapping, mappings) do
      {:ok, %{repository | lid_mapping: lid_mapping}}
    end
  end

  @spec get_lid_for_pn(t(), String.t()) :: {:ok, t(), String.t() | nil}
  def get_lid_for_pn(%__MODULE__{} = repository, pn) do
    with {:ok, lid_mapping, lid} <- LIDMappingStore.get_lid_for_pn(repository.lid_mapping, pn) do
      {:ok, %{repository | lid_mapping: lid_mapping}, lid}
    end
  end

  @spec get_pn_for_lid(t(), String.t()) :: {:ok, t(), String.t() | nil}
  def get_pn_for_lid(%__MODULE__{} = repository, lid) do
    with {:ok, lid_mapping, pn} <- LIDMappingStore.get_pn_for_lid(repository.lid_mapping, lid) do
      {:ok, %{repository | lid_mapping: lid_mapping}, pn}
    end
  end

  @spec migrate_session(t(), String.t(), String.t()) ::
          {:ok, t(), migration_result()} | {:error, adapter_error()}
  def migrate_session(%__MODULE__{} = repository, from_jid, to_jid)
      when is_binary(from_jid) and is_binary(to_jid) do
    with {:ok, user, lid_user, lid_server, source_device} <- normalize_migration(from_jid, to_jid),
         {:ok, adapter_state, device_list} <-
           repository.adapter.get_device_list(repository.adapter_state, user),
         {:ok, operations} <-
           build_migration_operations(user, lid_user, lid_server, device_list, source_device),
         {:ok, adapter_state, result} <-
           repository.adapter.migrate_sessions(adapter_state, operations) do
      {:ok, %{repository | adapter_state: adapter_state}, result}
    else
      error -> normalize_migration_error(repository, error)
    end
  end

  def migrate_session(%__MODULE__{} = repository, _from_jid, _to_jid) do
    {:ok, repository, %{migrated: 0, skipped: 0, total: 0}}
  end

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

  defp normalize_migration(from_jid, to_jid) do
    case {parse_pn_source(from_jid), parse_lid_target(to_jid)} do
      {{:ok, from}, {:ok, to}} ->
        {:ok, from.user, to.user, to.server, from.device}

      _ ->
        :unsupported_direction
    end
  end

  defp normalize_migration_error(repository, :unsupported_direction) do
    {:ok, repository, %{migrated: 0, skipped: 0, total: 0}}
  end

  defp normalize_migration_error(_repository, {:error, _reason} = error), do: error

  defp parse_pn_source(jid) do
    case BaileysEx.Protocol.JID.parse(jid) do
      %BaileysEx.JID{user: user, server: server, device: device}
      when is_binary(user) and server in ["s.whatsapp.net", "hosted"] ->
        {:ok, %{original: jid, user: user, device: device || 0}}

      _ ->
        :error
    end
  end

  defp parse_lid_target(jid) do
    case BaileysEx.Protocol.JID.parse(jid) do
      %BaileysEx.JID{user: user, server: server}
      when is_binary(user) and server in ["lid", "hosted.lid"] ->
        {:ok, %{original: jid, user: user, server: server}}

      _ ->
        :error
    end
  end

  defp build_migration_operations(_user, _lid_user, _lid_server, nil, _source_device) do
    {:ok, []}
  end

  defp build_migration_operations(user, lid_user, lid_server, device_list, source_device) do
    devices =
      device_list
      |> List.wrap()
      |> append_source_device(source_device)
      |> Enum.uniq()

    operations =
      Enum.reduce(devices, [], fn device, acc ->
        case build_migration_operation(user, lid_user, lid_server, device) do
          {:ok, operation} -> [operation | acc]
          :skip -> acc
        end
      end)
      |> Enum.reverse()

    {:ok, operations}
  end

  defp append_source_device(devices, source_device) do
    source_device = Integer.to_string(source_device)

    if source_device in devices do
      devices
    else
      devices ++ [source_device]
    end
  end

  defp build_migration_operation(user, lid_user, lid_server, device) when is_binary(device) do
    with {:ok, device_id} <- parse_device_id(device),
         from_jid <- build_pn_device_jid(user, device_id),
         to_jid <- build_lid_device_jid(lid_user, lid_server, device_id),
         {:ok, from_address} <- Address.from_jid(from_jid),
         {:ok, to_address} <- Address.from_jid(to_jid) do
      {:ok,
       %{
         from: from_address,
         to: to_address,
         pn_user: user,
         lid_user: lid_user,
         device_id: device_id
       }}
    else
      :error -> :skip
      {:error, :invalid_signal_address} -> :skip
    end
  end

  defp parse_device_id(device) do
    case Integer.parse(device) do
      {device_id, ""} when device_id >= 0 -> {:ok, device_id}
      _ -> :error
    end
  end

  defp build_pn_device_jid(user, 0), do: "#{user}@s.whatsapp.net"
  defp build_pn_device_jid(user, 99), do: "#{user}:99@hosted"
  defp build_pn_device_jid(user, device_id), do: "#{user}:#{device_id}@s.whatsapp.net"

  defp build_lid_device_jid(lid_user, lid_server, 0), do: "#{lid_user}@#{lid_server}"

  defp build_lid_device_jid(lid_user, lid_server, device_id),
    do: "#{lid_user}:#{device_id}@#{lid_server}"

  defp sender_key_name(group, jid) do
    with {:ok, address} <- Address.from_jid(jid) do
      {:ok, BaileysEx.Signal.Group.SenderKeyName.new(group, address)}
    end
  end
end
