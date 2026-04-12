defmodule BaileysEx.Syncd.Codec do
  @moduledoc """
  Syncd protocol codec — encode/decode snapshots, patches, and mutations
  with MAC generation and verification.

  Pure functions that implement the Baileys Syncd data transformation pipeline.
  All crypto operations use Erlang `:crypto`. Non-deterministic inputs (random IV)
  are injectable via options for testing.

  Ports `chat-utils.ts:45-489` — `generateMac`, `generateSnapshotMac`,
  `generatePatchMac`, `makeLtHashGenerator`, `decodeSyncdMutations`,
  `decodeSyncdPatch`, `decodeSyncdSnapshot`, `decodePatches`, `encodeSyncdPatch`,
  `extractSyncdPatches`.
  """

  alias BaileysEx.Crypto
  alias BaileysEx.Media.Download
  alias BaileysEx.Protocol.Proto.Syncd
  alias BaileysEx.Syncd.Keys
  alias BaileysEx.Util.LTHash

  @type lt_hash_state :: %{
          version: non_neg_integer(),
          hash: binary(),
          index_value_map: %{String.t() => %{value_mac: binary()}}
        }

  @type mutation_operation :: :set | :remove

  @type chat_mutation :: %{
          sync_action: map(),
          index: [String.t()]
        }

  @type chat_mutation_map :: %{String.t() => chat_mutation()}
  @type chat_mutation_order :: [chat_mutation()]

  @type patch_name ::
          :critical_block
          | :critical_unblock_low
          | :regular_high
          | :regular_low
          | :regular

  @patch_names ~w(critical_block critical_unblock_low regular_high regular_low regular)a

  # ============================================================================
  # LTHash state
  # ============================================================================

  @doc """
  Create a fresh LTHash state with version 0 and a 128-byte zero hash.

  Ports `newLTHashState()` from `chat-utils.ts:130`.
  """
  @spec new_lt_hash_state() :: lt_hash_state()
  def new_lt_hash_state do
    %{version: 0, hash: LTHash.new(), index_value_map: %{}}
  end

  @doc "Valid Syncd collection names."
  @spec patch_names() :: [patch_name()]
  def patch_names, do: @patch_names

  # ============================================================================
  # MAC generation — chat-utils.ts:45-128
  # ============================================================================

  @doc """
  Generate a value MAC for a mutation record.

  HMAC-SHA512 over `(op_byte || key_id) || encrypted_value || (8-byte length)`,
  truncated to the first 32 bytes.

  Ports `generateMac` from `chat-utils.ts:45-67`.
  """
  @spec generate_mac(mutation_operation(), binary(), binary(), binary()) :: binary()
  def generate_mac(operation, data, key_id, key) do
    op_byte = Syncd.SyncdMutation.operation_byte(operation)

    key_data = <<op_byte::8, key_id::binary>>

    # 8-byte trailer: last byte = length of key_data
    last = <<0::56, byte_size(key_data)::8>>

    total = <<key_data::binary, data::binary, last::binary>>
    :crypto.mac(:hmac, :sha512, key, total) |> binary_part(0, 32)
  end

  @doc """
  Generate a snapshot MAC from the LTHash state.

  HMAC-SHA256 over `lt_hash || version_64bit_be || name_utf8`.

  Ports `generateSnapshotMac` from `chat-utils.ts:114-117`.
  """
  @spec generate_snapshot_mac(binary(), non_neg_integer(), patch_name(), binary()) :: binary()
  def generate_snapshot_mac(lt_hash, version, name, key) do
    name_str = Atom.to_string(name)
    total = <<lt_hash::binary, to_64bit_network_order(version)::binary, name_str::binary>>
    :crypto.mac(:hmac, :sha256, key, total)
  end

  @doc """
  Generate a patch MAC that chains to the previous snapshot.

  HMAC-SHA256 over `snapshot_mac || value_macs... || version_64bit_be || name_utf8`.

  Ports `generatePatchMac` from `chat-utils.ts:119-128`.
  """
  @spec generate_patch_mac(binary(), [binary()], non_neg_integer(), patch_name(), binary()) ::
          binary()
  def generate_patch_mac(snapshot_mac, value_macs, version, type, key) do
    type_str = Atom.to_string(type)
    macs_bin = IO.iodata_to_binary(value_macs)

    total =
      <<snapshot_mac::binary, macs_bin::binary, to_64bit_network_order(version)::binary,
        type_str::binary>>

    :crypto.mac(:hmac, :sha256, key, total)
  end

  # ============================================================================
  # LTHash generator — chat-utils.ts:77-112
  # ============================================================================

  @doc """
  Create an LTHash generator that accumulates mix operations.

  Returns `{state, mix_fn, finish_fn}` where:
  - `mix_fn.(state, %{index_mac:, value_mac:, operation:})` → updated state
  - `finish_fn.(state)` → `%{hash:, index_value_map:}`

  This is a functional equivalent of Baileys' closure-based `makeLtHashGenerator`.
  Use with `Enum.reduce/3` over mutations.
  """
  @spec init_lt_hash_generator(lt_hash_state()) :: %{
          index_value_map: map(),
          add_buffs: [binary()],
          sub_buffs: [binary()],
          hash: binary()
        }
  def init_lt_hash_generator(%{index_value_map: ivm, hash: hash}) do
    %{
      index_value_map: Map.new(ivm),
      add_buffs: [],
      sub_buffs: [],
      hash: hash
    }
  end

  @doc """
  Mix a single mutation into the LTHash generator state.

  Ports the `mix()` closure from `makeLtHashGenerator` in `chat-utils.ts:83-101`.
  """
  @spec mix_mutation(map(), %{
          index_mac: binary(),
          value_mac: binary(),
          operation: mutation_operation()
        }) :: map()
  def mix_mutation(gen, %{index_mac: index_mac, value_mac: value_mac, operation: operation}) do
    index_mac_b64 = Base.encode64(index_mac)
    prev_op = Map.get(gen.index_value_map, index_mac_b64)

    # The JS Baileys mix() also throws on this case (chat-utils.ts:88), but the
    # caller in chats.ts:559-620 catches it, nulls the collection state, and retries.
    # The Coordinator lacks equivalent error handling, so we skip the no-op remove
    # instead of raising. See: https://github.com/jeffhuen/baileys_ex/issues/14
    if operation == :remove and is_nil(prev_op) do
      gen
    else
      gen =
        if operation == :remove do
          %{gen | index_value_map: Map.delete(gen.index_value_map, index_mac_b64)}
        else
          gen = %{gen | add_buffs: [value_mac | gen.add_buffs]}
          %{gen | index_value_map: Map.put(gen.index_value_map, index_mac_b64, %{value_mac: value_mac})}
        end

      if prev_op do
        %{gen | sub_buffs: [prev_op.value_mac | gen.sub_buffs]}
      else
        gen
      end
    end
  end

  @doc """
  Finalize the LTHash generator — apply accumulated adds/subs to the hash.

  Ports the `finish()` closure from `makeLtHashGenerator` in `chat-utils.ts:103-111`.
  """
  @spec finish_lt_hash_generator(map()) :: %{hash: binary(), index_value_map: map()}
  def finish_lt_hash_generator(gen) do
    # Reverse because we prepended during mix
    result =
      LTHash.subtract_then_add(
        gen.hash,
        Enum.reverse(gen.sub_buffs),
        Enum.reverse(gen.add_buffs)
      )

    %{hash: result, index_value_map: gen.index_value_map}
  end

  # ============================================================================
  # Decode mutations — chat-utils.ts:197-270
  # ============================================================================

  @doc """
  Decode a list of Syncd mutations, verifying MACs and decrypting values.

  For each mutation:
  1. Extract operation and record
  2. Fetch decryption key via `get_app_state_sync_key` callback
  3. Verify value MAC (if `validate_macs`)
  4. AES-256-CBC decrypt the value
  5. Decode SyncActionData protobuf
  6. Verify index MAC (if `validate_macs`)
  7. Call `on_mutation` callback
  8. Mix into LTHash generator

  Returns the updated LTHash state (hash + index_value_map).

  Ports `decodeSyncdMutations` from `chat-utils.ts:197-270`.
  """
  @spec decode_syncd_mutations(
          [map()],
          lt_hash_state(),
          (String.t() -> {:ok, map()} | {:error, term()}),
          (chat_mutation() -> any()),
          boolean()
        ) :: {:ok, %{hash: binary(), index_value_map: map()}} | {:error, term()}
  def decode_syncd_mutations(
        msg_mutations,
        initial_state,
        get_app_state_sync_key,
        on_mutation,
        validate_macs
      ) do
    reducer = fn mutation, acc ->
      on_mutation.(mutation)
      acc
    end

    case decode_syncd_mutations_reduce(
           msg_mutations,
           initial_state,
           get_app_state_sync_key,
           validate_macs,
           :ok,
           reducer
         ) do
      {:ok, %{state: state}} -> {:ok, state}
      {:error, _} = err -> err
    end
  end

  defp decode_syncd_mutations_reduce(
         msg_mutations,
         initial_state,
         get_app_state_sync_key,
         validate_macs,
         initial_acc,
         reducer
       ) do
    gen = init_lt_hash_generator(initial_state)
    key_cache = %{}

    result =
      Enum.reduce_while(msg_mutations, {:ok, gen, key_cache, initial_acc}, fn msg_mutation,
                                                                              {:ok, gen_acc,
                                                                               cache, acc} ->
        case decode_single_mutation(
               msg_mutation,
               get_app_state_sync_key,
               validate_macs,
               gen_acc,
               cache
             ) do
          {:ok, mutation, new_gen, new_cache} ->
            {:cont, {:ok, new_gen, new_cache, reducer.(mutation, acc)}}

          {:error, _reason} = err ->
            {:halt, err}
        end
      end)

    case result do
      {:ok, final_gen, _cache, acc} ->
        {:ok, %{state: finish_lt_hash_generator(final_gen), acc: acc}}

      {:error, _} = err ->
        err
    end
  end

  defp decode_single_mutation(msg_mutation, get_key_fn, validate_macs, gen, cache) do
    # Extract operation and record — chat-utils.ts:213-215
    {operation, record} = extract_operation_and_record(msg_mutation)

    with {:ok, key_id_bin} <- extract_key_id(record),
         {:ok, keys, cache} <- get_cached_keys(key_id_bin, get_key_fn, cache),
         {:ok, enc_content, og_value_mac} <- extract_value_parts(record),
         :ok <-
           verify_value_mac(
             validate_macs,
             operation,
             enc_content,
             key_id_bin,
             keys.value_mac_key,
             og_value_mac
           ),
         {:ok, decrypted} <- aes_cbc_decrypt_with_iv(enc_content, keys.value_encryption_key),
         {:ok, sync_action_data} <- Syncd.SyncActionData.decode(decrypted),
         :ok <- verify_index_mac(validate_macs, sync_action_data.index, keys.index_key, record),
         {:ok, index_array} <- parse_index(sync_action_data.index) do
      mutation = %{sync_action: sync_action_data, index: index_array}

      index_mac = record.index.blob

      new_gen =
        mix_mutation(gen, %{
          index_mac: index_mac,
          value_mac: og_value_mac,
          operation: operation
        })

      {:ok, mutation, new_gen, cache}
    end
  end

  defp extract_operation_and_record(%Syncd.SyncdMutation{operation: op, record: record})
       when not is_nil(record) do
    {Syncd.SyncdMutation.operation_atom(op), record}
  end

  defp extract_operation_and_record(%Syncd.SyncdRecord{} = record) do
    {:set, record}
  end

  defp extract_key_id(%Syncd.SyncdRecord{key_id: %Syncd.KeyId{id: id}}) when is_binary(id) do
    {:ok, id}
  end

  defp extract_key_id(_), do: {:error, :missing_key_id}

  defp extract_value_parts(%Syncd.SyncdRecord{value: %Syncd.SyncdValue{blob: blob}})
       when is_binary(blob) and byte_size(blob) > 32 do
    size = byte_size(blob)
    enc_content = binary_part(blob, 0, size - 32)
    value_mac = binary_part(blob, size - 32, 32)
    {:ok, enc_content, value_mac}
  end

  defp extract_value_parts(_), do: {:error, :invalid_value_blob}

  defp get_cached_keys(key_id_bin, get_key_fn, cache) do
    b64 = Base.encode64(key_id_bin)

    case Map.get(cache, b64) do
      nil ->
        case get_key_fn.(b64) do
          {:ok, %{key_data: key_data}} when is_binary(key_data) ->
            keys = Keys.mutation_keys(key_data)
            {:ok, keys, Map.put(cache, b64, keys)}

          {:error, _} = err ->
            err

          _ ->
            {:error, {:key_not_found, b64}}
        end

      keys ->
        {:ok, keys, cache}
    end
  end

  defp verify_value_mac(false, _op, _enc, _kid, _key, _mac), do: :ok

  defp verify_value_mac(true, operation, enc_content, key_id_bin, value_mac_key, og_value_mac) do
    computed = generate_mac(operation, enc_content, key_id_bin, value_mac_key)

    if computed == og_value_mac do
      :ok
    else
      {:error, :hmac_content_verification_failed}
    end
  end

  defp verify_index_mac(false, _index, _key, _record), do: :ok

  defp verify_index_mac(true, index_bytes, index_key, record) do
    computed = :crypto.mac(:hmac, :sha256, index_key, index_bytes)

    if computed == record.index.blob do
      :ok
    else
      {:error, :hmac_index_verification_failed}
    end
  end

  defp parse_index(index_bytes) when is_binary(index_bytes) do
    case JSON.decode(index_bytes) do
      {:ok, list} when is_list(list) -> {:ok, list}
      _ -> {:error, :invalid_index_json}
    end
  end

  # ============================================================================
  # Decode patch — chat-utils.ts:272-304
  # ============================================================================

  @doc """
  Decode a single Syncd patch, verifying the patch MAC and decoding all mutations.

  Ports `decodeSyncdPatch` from `chat-utils.ts:272-304`.
  """
  @spec decode_syncd_patch(
          map(),
          patch_name(),
          lt_hash_state(),
          (String.t() -> {:ok, map()} | {:error, term()}),
          (chat_mutation() -> any()),
          boolean()
        ) :: {:ok, %{hash: binary(), index_value_map: map()}} | {:error, term()}
  def decode_syncd_patch(
        msg,
        name,
        initial_state,
        get_app_state_sync_key,
        on_mutation,
        validate_macs
      ) do
    reducer = fn mutation, acc ->
      on_mutation.(mutation)
      acc
    end

    case decode_syncd_patch_reduce(
           msg,
           name,
           initial_state,
           get_app_state_sync_key,
           validate_macs,
           :ok,
           reducer
         ) do
      {:ok, %{state: state}} -> {:ok, state}
      {:error, _} = err -> err
    end
  end

  defp decode_syncd_patch_reduce(
         msg,
         name,
         initial_state,
         get_app_state_sync_key,
         validate_macs,
         initial_acc,
         reducer
       ) do
    with :ok <- verify_patch_mac(validate_macs, msg, name, get_app_state_sync_key),
         {:ok, %{state: state, acc: acc}} <-
           decode_syncd_mutations_reduce(
             msg.mutations,
             initial_state,
             get_app_state_sync_key,
             validate_macs,
             initial_acc,
             reducer
           ) do
      {:ok, %{state: state, acc: acc}}
    end
  end

  defp verify_patch_mac(false, _msg, _name, _get_key), do: :ok

  defp verify_patch_mac(true, msg, name, get_key) do
    b64 = Base.encode64(msg.key_id.id)

    with {:ok, key_obj} <- get_key.(b64),
         true <- is_binary(key_obj.key_data) || {:error, :missing_key_data} do
      main_key = Keys.mutation_keys(key_obj.key_data)

      mutation_macs =
        Enum.map(msg.mutations, fn mutation ->
          blob = mutation.record.value.blob
          binary_part(blob, byte_size(blob) - 32, 32)
        end)

      version = msg.version.version

      computed =
        generate_patch_mac(
          msg.snapshot_mac,
          mutation_macs,
          version,
          name,
          main_key.patch_mac_key
        )

      if computed == msg.patch_mac do
        :ok
      else
        {:error, :invalid_patch_mac}
      end
    end
  end

  # ============================================================================
  # Decode snapshot — chat-utils.ts:374-420
  # ============================================================================

  @doc """
  Decode a full Syncd snapshot, verifying the snapshot MAC and extracting all mutations.

  Ports `decodeSyncdSnapshot` from `chat-utils.ts:374-420`.
  """
  @spec decode_syncd_snapshot(
          patch_name(),
          map(),
          (String.t() -> {:ok, map()} | {:error, term()}),
          non_neg_integer() | nil,
          boolean()
        ) ::
          {:ok,
           %{
             state: lt_hash_state(),
             mutation_map: chat_mutation_map(),
             mutation_order: chat_mutation_order()
           }}
          | {:error, term()}
  def decode_syncd_snapshot(
        name,
        snapshot,
        get_app_state_sync_key,
        minimum_version_number \\ nil,
        validate_macs \\ true
      ) do
    new_state = %{new_lt_hash_state() | version: snapshot.version.version}

    are_mutations_required =
      is_nil(minimum_version_number) or new_state.version > minimum_version_number

    case decode_syncd_mutations_reduce(
           snapshot.records,
           new_state,
           get_app_state_sync_key,
           validate_macs,
           [],
           snapshot_mutation_reducer(are_mutations_required)
         ) do
      {:ok, %{state: %{hash: hash, index_value_map: ivm}, acc: mutations}} ->
        mutation_order = Enum.reverse(mutations)
        mutation_map = mutation_order_to_map(mutation_order)
        final_state = %{new_state | hash: hash, index_value_map: ivm}

        with :ok <-
               verify_snapshot_mac(
                 validate_macs,
                 snapshot,
                 final_state,
                 name,
                 get_app_state_sync_key
               ) do
          {:ok, %{state: final_state, mutation_map: mutation_map, mutation_order: mutation_order}}
        end

      {:error, _} = err ->
        err
    end
  end

  defp verify_snapshot_mac(false, _snapshot, _state, _name, _get_key), do: :ok

  defp verify_snapshot_mac(true, snapshot, state, name, get_key) do
    b64 = Base.encode64(snapshot.key_id.id)

    with {:ok, key_obj} <- get_key.(b64),
         true <- is_binary(key_obj.key_data) || {:error, :missing_key_data} do
      keys = Keys.mutation_keys(key_obj.key_data)
      computed = generate_snapshot_mac(state.hash, state.version, name, keys.snapshot_mac_key)

      if computed == snapshot.mac do
        :ok
      else
        {:error, :invalid_snapshot_mac}
      end
    end
  end

  # ============================================================================
  # Decode patches sequence — chat-utils.ts:422-489
  # ============================================================================

  @doc """
  Decode a sequence of Syncd patches, maintaining state across them.

  Ports `decodePatches` from `chat-utils.ts:422-489`.
  """
  @spec decode_patches(
          patch_name(),
          [map()],
          lt_hash_state(),
          (String.t() -> {:ok, map()} | {:error, term()}),
          non_neg_integer() | nil,
          boolean(),
          keyword()
        ) ::
          {:ok,
           %{
             state: lt_hash_state(),
             mutation_map: chat_mutation_map(),
             mutation_order: chat_mutation_order()
           }}
          | {:error, term()}
  def decode_patches(
        name,
        patches,
        initial,
        get_app_state_sync_key,
        minimum_version_number \\ nil,
        validate_macs \\ true,
        opts \\ []
      ) do
    new_state = %{initial | index_value_map: Map.new(initial.index_value_map)}
    mutation_map = %{}
    mutation_order = []
    external_blob_fetcher = Keyword.get(opts, :external_blob_fetcher, &download_external_blob/1)

    result =
      Enum.reduce_while(patches, {:ok, new_state, mutation_map, mutation_order}, fn syncd,
                                                                                    {:ok, state,
                                                                                     mut_map,
                                                                                     mut_order} ->
        case maybe_expand_external_mutations(syncd, external_blob_fetcher) do
          {:ok, expanded_syncd} ->
            expanded_syncd
            |> decode_patch_result(
              name,
              state,
              mut_map,
              mut_order,
              get_app_state_sync_key,
              minimum_version_number,
              validate_macs
            )
            |> continue_patch_reduction()

          {:error, _} = err ->
            {:halt, err}
        end
      end)

    case result do
      {:ok, final_state, final_map, final_order} ->
        {:ok, %{state: final_state, mutation_map: final_map, mutation_order: final_order}}

      {:error, _} = err ->
        err
    end
  end

  # ============================================================================
  # Encode patch — chat-utils.ts:132-195
  # ============================================================================

  @doc """
  Encode a single outbound Syncd patch.

  Steps:
  1. Fetch encryption key via `get_app_state_sync_key`
  2. Encode SyncActionData protobuf
  3. AES-256-CBC encrypt with random IV (injectable via `opts[:iv]`)
  4. Generate value MAC, index MAC
  5. Update LTHash state
  6. Generate snapshot MAC, patch MAC
  7. Build SyncdPatch protobuf

  Returns `{:ok, %{patch: SyncdPatch.t(), state: lt_hash_state()}}`.

  Ports `encodeSyncdPatch` from `chat-utils.ts:132-195`.
  """
  @spec encode_syncd_patch(
          map(),
          String.t(),
          lt_hash_state(),
          (String.t() -> {:ok, map()} | {:error, term()}),
          keyword()
        ) ::
          {:ok, %{patch: map(), state: lt_hash_state()}} | {:error, term()}
  def encode_syncd_patch(
        patch_create,
        my_app_state_key_id,
        state,
        get_app_state_sync_key,
        opts \\ []
      ) do
    with {:ok, key_obj} <- get_app_state_sync_key.(my_app_state_key_id),
         true <- is_binary(key_obj.key_data) || {:error, :missing_key_data} do
      enc_key_id = Base.decode64!(my_app_state_key_id)
      state = %{state | index_value_map: Map.new(state.index_value_map)}

      # Encode SyncActionData protobuf
      index_buffer = JSON.encode!(patch_create.index)

      data_proto = %Syncd.SyncActionData{
        index: index_buffer,
        value: patch_create.sync_action,
        padding: <<>>,
        version: patch_create.api_version
      }

      encoded = Syncd.SyncActionData.encode(data_proto)

      # Derive keys
      key_value = Keys.mutation_keys(key_obj.key_data)

      # Encrypt value — random IV prepended (injectable for tests)
      iv = Keyword.get_lazy(opts, :iv, fn -> :crypto.strong_rand_bytes(16) end)
      {:ok, ciphertext} = Crypto.aes_cbc_encrypt(key_value.value_encryption_key, iv, encoded)
      enc_value = <<iv::binary-16, ciphertext::binary>>

      # Generate MACs
      value_mac =
        generate_mac(patch_create.operation, enc_value, enc_key_id, key_value.value_mac_key)

      index_mac = :crypto.mac(:hmac, :sha256, key_value.index_key, index_buffer)

      # Update LTHash
      gen = init_lt_hash_generator(state)

      gen =
        mix_mutation(gen, %{
          index_mac: index_mac,
          value_mac: value_mac,
          operation: patch_create.operation
        })

      %{hash: hash, index_value_map: ivm} = finish_lt_hash_generator(gen)

      state = %{state | hash: hash, index_value_map: ivm, version: state.version + 1}

      # Generate snapshot and patch MACs
      snapshot_mac =
        generate_snapshot_mac(
          state.hash,
          state.version,
          patch_create.type,
          key_value.snapshot_mac_key
        )

      patch_mac =
        generate_patch_mac(
          snapshot_mac,
          [value_mac],
          state.version,
          patch_create.type,
          key_value.patch_mac_key
        )

      # Build protobuf
      patch = %Syncd.SyncdPatch{
        patch_mac: patch_mac,
        snapshot_mac: snapshot_mac,
        key_id: %Syncd.KeyId{id: enc_key_id},
        mutations: [
          %Syncd.SyncdMutation{
            operation: patch_create.operation,
            record: %Syncd.SyncdRecord{
              index: %Syncd.SyncdIndex{blob: index_mac},
              value: %Syncd.SyncdValue{blob: <<enc_value::binary, value_mac::binary>>},
              key_id: %Syncd.KeyId{id: enc_key_id}
            }
          }
        ]
      }

      # Update index_value_map
      b64_index = Base.encode64(index_mac)
      state = put_in(state.index_value_map[b64_index], %{value_mac: value_mac})

      {:ok, %{patch: patch, state: state}}
    end
  end

  # ============================================================================
  # Extract patches from binary node — chat-utils.ts:306-356
  # ============================================================================

  @doc """
  Extract Syncd patches and snapshots from a server response binary node.

  Ports `extractSyncdPatches` from `chat-utils.ts:306-356`.
  """
  @spec extract_syncd_patches(map(), keyword()) ::
          {:ok,
           %{
             atom() => %{
               patches: [map()],
               has_more_patches: boolean(),
               snapshot: map() | nil
             }
           }}
          | {:error, term()}
  def extract_syncd_patches(response, opts \\ [])

  def extract_syncd_patches(%{tag: "iq", content: content}, opts) when is_list(content) do
    sync_node = Enum.find(content, &(&1.tag == "sync"))
    collection_nodes = if sync_node, do: get_children(sync_node, "collection"), else: []
    external_blob_fetcher = Keyword.get(opts, :external_blob_fetcher, &download_external_blob/1)

    Enum.reduce_while(collection_nodes, {:ok, %{}}, fn collection_node, {:ok, acc} ->
      case decode_collection_node(collection_node, external_blob_fetcher) do
        {:ok, name, payload} ->
          {:cont, {:ok, Map.put(acc, name, payload)}}

        {:error, _} = err ->
          {:halt, err}
      end
    end)
  end

  def extract_syncd_patches(_, _opts), do: {:ok, %{}}

  # ============================================================================
  # Private helpers
  # ============================================================================

  defp to_64bit_network_order(value) when is_integer(value) do
    <<value::unsigned-big-64>>
  end

  defp aes_cbc_decrypt_with_iv(data, key) when byte_size(data) > 16 do
    <<iv::binary-16, ciphertext::binary>> = data
    Crypto.aes_cbc_decrypt(key, iv, ciphertext)
  end

  defp aes_cbc_decrypt_with_iv(_data, _key), do: {:error, :data_too_short}

  defp maybe_expand_external_mutations(
         %Syncd.SyncdPatch{external_mutations: %Syncd.ExternalBlobReference{} = blob_ref} = syncd,
         external_blob_fetcher
       ) do
    with {:ok, data} <- external_blob_fetcher.(blob_ref),
         {:ok, %Syncd.SyncdMutations{mutations: mutations}} <- Syncd.SyncdMutations.decode(data) do
      {:ok, %{syncd | mutations: syncd.mutations ++ mutations}}
    end
  end

  defp maybe_expand_external_mutations(%Syncd.SyncdPatch{} = syncd, _external_blob_fetcher),
    do: {:ok, syncd}

  defp decode_snapshot_node(nil, _external_blob_fetcher), do: {:ok, nil}

  defp decode_snapshot_node(%{content: content}, external_blob_fetcher) do
    case node_binary_content(content) do
      nil ->
        {:ok, nil}

      binary ->
        decode_snapshot_binary(binary, external_blob_fetcher)
    end
  end

  defp decode_snapshot_node(_snapshot_node, _external_blob_fetcher), do: {:ok, nil}

  defp decode_snapshot_binary(content, external_blob_fetcher) when is_binary(content) do
    case Syncd.ExternalBlobReference.decode(content) do
      {:ok, blob_ref} ->
        case external_blob_fetcher.(blob_ref) do
          {:ok, data} -> Syncd.SyncdSnapshot.decode(data)
          {:error, _} = err -> err
        end

      {:error, _} ->
        case Syncd.SyncdSnapshot.decode(content) do
          {:ok, snapshot} -> {:ok, snapshot}
          {:error, _} = err -> err
        end
    end
  end

  defp download_external_blob(%Syncd.ExternalBlobReference{} = blob_ref) do
    Download.download(blob_ref, media_type: :md_app_state)
  end

  defp find_child(%{content: content}, tag) when is_list(content) do
    Enum.find(content, fn
      %{tag: ^tag} -> true
      _ -> false
    end)
  end

  defp find_child(_, _), do: nil

  defp get_children(%{content: content}, tag) when is_list(content) do
    Enum.filter(content, fn
      %{tag: ^tag} -> true
      _ -> false
    end)
  end

  defp get_children(_, _), do: []

  defp decode_patch_result(
         syncd,
         name,
         state,
         mutation_map,
         mutation_order,
         get_app_state_sync_key,
         minimum_version_number,
         validate_macs
       ) do
    patch_version = syncd.version.version
    state = %{state | version: patch_version}
    should_mutate = is_nil(minimum_version_number) or patch_version > minimum_version_number

    with :ok <- verify_patch_mac(validate_macs, syncd, name, get_app_state_sync_key),
         {:ok, %{state: %{hash: hash, index_value_map: ivm}, acc: patch_mutations}} <-
           decode_syncd_mutations_reduce(
             syncd.mutations,
             state,
             get_app_state_sync_key,
             true,
             [],
             patch_mutation_reducer(should_mutate)
           ),
         patch_mutation_order = Enum.reverse(patch_mutations),
         next_mutation_map = Map.merge(mutation_map, mutation_order_to_map(patch_mutation_order)),
         next_mutation_order = mutation_order ++ patch_mutation_order,
         verified_state = %{state | hash: hash, index_value_map: ivm},
         :ok <-
           verify_snapshot_mac(
             validate_macs,
             %{key_id: syncd.key_id, mac: syncd.snapshot_mac},
             verified_state,
             name,
             get_app_state_sync_key
           ) do
      {:ok, verified_state, next_mutation_map, next_mutation_order}
    end
  end

  defp mutation_key(%{sync_action: %{index: index}}) when is_binary(index), do: index
  defp mutation_key(_mutation), do: ""

  defp snapshot_mutation_reducer(true) do
    fn mutation, acc ->
      [mutation | acc]
    end
  end

  defp snapshot_mutation_reducer(false), do: fn _mutation, acc -> acc end

  defp patch_mutation_reducer(true) do
    fn mutation, acc ->
      [mutation | acc]
    end
  end

  defp patch_mutation_reducer(false), do: fn _mutation, acc -> acc end

  defp continue_patch_reduction({:ok, next_state, next_mutation_map, next_mutation_order}) do
    {:cont, {:ok, next_state, next_mutation_map, next_mutation_order}}
  end

  defp continue_patch_reduction({:error, _} = err), do: {:halt, err}

  defp decode_collection_node(collection_node, external_blob_fetcher) do
    name = String.to_existing_atom(collection_node.attrs["name"])
    has_more = collection_node.attrs["has_more_patches"] == "true"

    with {:ok, snapshot} <-
           decode_snapshot_node(find_child(collection_node, "snapshot"), external_blob_fetcher) do
      {:ok, name,
       %{
         patches: decode_collection_patches(collection_node),
         has_more_patches: has_more,
         snapshot: snapshot
       }}
    end
  end

  defp decode_collection_patches(collection_node) do
    collection_node
    |> collection_patch_nodes()
    |> Enum.flat_map(&decode_collection_patch(&1, collection_node))
  end

  defp collection_patch_nodes(collection_node) do
    collection_node
    |> find_child("patches")
    |> Kernel.||(collection_node)
    |> get_children("patch")
  end

  defp decode_collection_patch(%{content: content}, collection_node) do
    case node_binary_content(content) do
      binary when is_binary(binary) ->
        case Syncd.SyncdPatch.decode(binary) do
          {:ok, patch} -> [ensure_patch_version(patch, collection_node.attrs["version"])]
          _ -> []
        end

      _ ->
        []
    end
  end

  defp decode_collection_patch(_node, _collection_node), do: []

  defp node_binary_content({:binary, binary}) when is_binary(binary), do: binary
  defp node_binary_content(binary) when is_binary(binary), do: binary
  defp node_binary_content(_content), do: nil

  defp ensure_patch_version(%Syncd.SyncdPatch{version: nil} = patch, collection_version) do
    version = String.to_integer(collection_version) + 1
    %{patch | version: %Syncd.SyncdVersion{version: version}}
  end

  defp ensure_patch_version(%Syncd.SyncdPatch{} = patch, _collection_version), do: patch

  defp mutation_order_to_map(mutation_order) do
    Enum.reduce(mutation_order, %{}, fn mutation, acc ->
      Map.put(acc, mutation_key(mutation), mutation)
    end)
  end
end
