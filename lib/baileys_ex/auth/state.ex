defmodule BaileysEx.Auth.State do
  @moduledoc """
  Authentication credential state matching the Baileys rc.9 auth envelope.
  """

  alias BaileysEx.Crypto
  alias BaileysEx.Signal.Curve

  @type key_pair :: %{public: binary(), private: binary()}
  @type signed_key_pair :: %{
          key_pair: key_pair(),
          key_id: non_neg_integer(),
          signature: binary()
        }
  @type signal_identity :: %{
          identifier: %{name: binary(), device_id: non_neg_integer()},
          identifier_key: binary()
        }
  @type account_settings :: %{
          unarchive_chats: boolean(),
          default_disappearing_mode: map() | nil
        }

  @type json_safe ::
          nil
          | boolean()
          | number()
          | binary()
          | [json_safe()]
          | %{optional(binary()) => json_safe()}

  @type t :: %__MODULE__{
          noise_key: key_pair(),
          pairing_ephemeral_key: key_pair() | nil,
          signed_identity_key: key_pair(),
          signed_pre_key: signed_key_pair(),
          registration_id: non_neg_integer(),
          adv_secret_key: binary(),
          account: map() | nil,
          me: map() | nil,
          signal_identities: [signal_identity()],
          platform: binary() | nil,
          last_account_sync_timestamp: integer() | nil,
          processed_history_messages: [map()],
          account_sync_counter: non_neg_integer(),
          account_settings: account_settings(),
          registered: boolean(),
          pairing_code: binary() | nil,
          last_prop_hash: binary() | nil,
          routing_info: binary() | nil,
          my_app_state_key_id: binary() | nil,
          additional_data: json_safe() | nil
        }

  defstruct [
    :account,
    :additional_data,
    :last_account_sync_timestamp,
    :last_prop_hash,
    :me,
    :my_app_state_key_id,
    :pairing_code,
    :platform,
    :routing_info,
    noise_key: nil,
    pairing_ephemeral_key: nil,
    signed_identity_key: nil,
    signed_pre_key: nil,
    registration_id: 0,
    adv_secret_key: nil,
    signal_identities: [],
    processed_history_messages: [],
    account_sync_counter: 0,
    account_settings: %{unarchive_chats: false, default_disappearing_mode: nil},
    registered: false,
    first_unuploaded_pre_key_id: 1,
    next_pre_key_id: 1
  ]

  @doc """
  Initializes a new authentication state with generated keys.
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) when is_list(opts) do
    identity_key = Keyword.get_lazy(opts, :signed_identity_key, &Curve.generate_key_pair/0)

    signed_pre_key =
      Keyword.get_lazy(opts, :signed_pre_key, fn ->
        {:ok, signed_pre_key} = Curve.signed_key_pair(identity_key, 1)
        signed_pre_key
      end)

    %__MODULE__{
      noise_key: Keyword.get_lazy(opts, :noise_key, &Curve.generate_key_pair/0),
      pairing_ephemeral_key:
        Keyword.get_lazy(opts, :pairing_ephemeral_key, &Curve.generate_key_pair/0),
      signed_identity_key: identity_key,
      signed_pre_key: signed_pre_key,
      registration_id: Keyword.get_lazy(opts, :registration_id, &generate_registration_id/0),
      adv_secret_key:
        Keyword.get_lazy(opts, :adv_secret_key, fn ->
          Crypto.random_bytes(32) |> Base.encode64()
        end),
      processed_history_messages: [],
      next_pre_key_id: 1,
      first_unuploaded_pre_key_id: 1,
      account_sync_counter: 0,
      account_settings: %{unarchive_chats: false, default_disappearing_mode: nil},
      registered: false,
      pairing_code: nil,
      last_prop_hash: nil,
      routing_info: nil,
      additional_data: nil
    }
  end

  def get(state, key, default \\ nil)

  @doc """
  Fetches a value from the auth state or its nested credentials structure.
  """
  @spec get(t() | map(), atom(), term()) :: term()
  def get(%__MODULE__{} = state, key, default) when is_atom(key) do
    case Map.fetch(state, key) do
      {:ok, nil} -> nested_creds_get(state, key, default)
      {:ok, value} -> value
      :error -> nested_creds_get(state, key, default)
    end
  end

  def get(%{} = state, key, default) when is_atom(key) do
    case Map.fetch(state, key) do
      {:ok, nil} -> nested_creds_get(state, key, default)
      {:ok, value} -> value
      :error -> nested_creds_get(state, key, default)
    end
  end

  def get(_state, _key, default), do: default

  @doc """
  Returns the current account name from the auth state when present.
  """
  @spec me_name(t() | map()) :: binary() | nil
  def me_name(state), do: me_field(state, :name)

  @doc """
  Returns the current account JID from the auth state when present.
  """
  @spec me_id(t() | map()) :: binary() | nil
  def me_id(state), do: me_field(state, :id)

  @doc """
  Returns the current LID from the auth state when present.
  """
  @spec me_lid(t() | map()) :: binary() | nil
  def me_lid(state), do: me_field(state, :lid)

  @doc """
  Returns a `creds` viewing projection mapping suitable for saving standalone.
  """
  @spec creds_view(t() | map()) :: map()
  def creds_view(%{creds: creds}) when is_map(creds), do: creds
  def creds_view(%__MODULE__{} = state), do: Map.from_struct(state)
  def creds_view(%{} = state), do: state
  def creds_view(_state), do: %{}

  @doc """
  Deeply merges arbitrary map updates into the authentication state struct.
  """
  @spec merge_updates(t() | map(), map()) :: t() | map()
  def merge_updates(%__MODULE__{} = state, updates) when is_map(updates) do
    Enum.reduce(updates, state, fn
      {key, value}, %__MODULE__{} = acc when key != :__struct__ and is_map(value) ->
        existing = Map.get(acc, key)

        if is_map(existing) do
          Map.put(acc, key, merge_maps(existing, value))
        else
          Map.put(acc, key, value)
        end

      {key, value}, %__MODULE__{} = acc when key != :__struct__ ->
        if Map.has_key?(acc, key) do
          Map.put(acc, key, value)
        else
          acc
        end
    end)
  end

  def merge_updates(%{creds: creds} = state, updates) when is_map(creds) and is_map(updates) do
    merge_maps(state, %{creds: updates})
  end

  def merge_updates(%{} = state, updates) when is_map(updates), do: merge_maps(state, updates)
  def merge_updates(state, _updates), do: state

  defp generate_registration_id do
    <<registration_id::unsigned-integer-size(16)>> = Crypto.random_bytes(2)
    Bitwise.band(registration_id, 16_383)
  end

  defp nested_creds_get(%{creds: creds}, key, default) when is_map(creds) do
    Map.get(creds, key, default)
  end

  defp nested_creds_get(_state, _key, default), do: default

  defp me_field(%{me: me}, field) when is_map(me), do: me_field(me, field)
  defp me_field(%{"me" => me}, field) when is_map(me), do: me_field(me, field)

  defp me_field(map, field) when is_map(map) do
    case Map.fetch(map, field) do
      {:ok, value} when is_binary(value) ->
        value

      _ ->
        case Map.get(map, Atom.to_string(field)) do
          value when is_binary(value) -> value
          _ -> nil
        end
    end
  end

  defp me_field(_state, _field), do: nil

  defp merge_maps(left, right) when is_map(left) and is_map(right) do
    Map.merge(left, right, fn _key, left_value, right_value ->
      if is_map(left_value) and is_map(right_value) do
        merge_maps(left_value, right_value)
      else
        right_value
      end
    end)
  end
end
