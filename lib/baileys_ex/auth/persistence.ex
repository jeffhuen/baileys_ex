defmodule BaileysEx.Auth.Persistence do
  @moduledoc """
  Persistence behaviour for auth credentials and key-store datasets.
  """

  alias BaileysEx.Auth.State

  @callback load_credentials() :: {:ok, State.t()} | {:error, term()}
  @callback save_credentials(State.t()) :: :ok | {:error, term()}
  @callback load_keys(type :: atom(), id :: term()) :: {:ok, term()} | {:error, term()}
  @callback save_keys(type :: atom(), id :: term(), data :: term()) :: :ok | {:error, term()}
  @callback delete_keys(type :: atom(), id :: term()) :: :ok | {:error, term()}
end
