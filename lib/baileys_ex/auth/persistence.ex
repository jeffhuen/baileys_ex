defmodule BaileysEx.Auth.Persistence do
  @moduledoc """
  Persistence behaviour for auth credentials and key-store datasets.

  Phase 15 supports two built-in file backends:

  - `BaileysEx.Auth.NativeFilePersistence` for the recommended durable
    Elixir-first ETF storage
  - `BaileysEx.Auth.FilePersistence` for the Baileys-compatible JSON multi-file
    helper

  Custom backends can implement either the context-free callbacks, the
  context-aware callbacks, or both. `BaileysEx.Auth.KeyStore` dispatches to the
  widest arity the backend exports.
  """

  alias BaileysEx.Auth.State

  @typedoc """
  Helper map returned by the built-in auth-state loaders.

  `connect_opts` is ready to merge into `BaileysEx.connect/2`, and `save_creds`
  persists the latest auth-state snapshot for the selected backend.
  """
  @type auth_state_helper :: %{
          required(:state) => State.t(),
          required(:connect_opts) => keyword(),
          required(:save_creds) => (State.t() | map() -> :ok | {:error, term()})
        }

  @callback load_credentials() :: {:ok, State.t()} | {:error, term()}
  @callback save_credentials(State.t()) :: :ok | {:error, term()}
  @callback load_keys(type :: atom(), id :: term()) :: {:ok, term()} | {:error, term()}
  @callback save_keys(type :: atom(), id :: term(), data :: term()) :: :ok | {:error, term()}
  @callback delete_keys(type :: atom(), id :: term()) :: :ok | {:error, term()}

  @callback load_credentials(context :: term()) :: {:ok, State.t()} | {:error, term()}
  @callback save_credentials(context :: term(), State.t()) :: :ok | {:error, term()}
  @callback load_keys(context :: term(), type :: atom(), id :: term()) ::
              {:ok, term()} | {:error, term()}
  @callback save_keys(context :: term(), type :: atom(), id :: term(), data :: term()) ::
              :ok | {:error, term()}
  @callback delete_keys(context :: term(), type :: atom(), id :: term()) ::
              :ok | {:error, term()}

  @optional_callbacks load_credentials: 1,
                      save_credentials: 2,
                      load_keys: 3,
                      save_keys: 4,
                      delete_keys: 3
end
