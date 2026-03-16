defmodule BaileysEx.Signal.SessionRecord do
  @moduledoc false

  @max_closed_sessions 40

  @type session :: %{
          current_ratchet: %{
            root_key: binary(),
            ephemeral_key_pair: %{public: binary(), private: binary()} | nil,
            last_remote_ephemeral: binary(),
            previous_counter: non_neg_integer()
          },
          index_info: %{
            remote_identity_key: binary(),
            local_identity_key: binary(),
            base_key: binary(),
            base_key_type: :sending | :receiving,
            closed: integer() | nil
          },
          chains: %{optional(binary()) => chain()},
          pending_pre_key: pending_pre_key() | nil,
          registration_id: non_neg_integer()
        }

  @type chain :: %{
          chain_key: %{counter: integer(), key: binary() | nil},
          chain_type: :sending | :receiving,
          message_keys: %{optional(non_neg_integer()) => binary()}
        }

  @type pending_pre_key :: %{
          pre_key_id: non_neg_integer() | nil,
          signed_pre_key_id: non_neg_integer(),
          base_key: binary()
        }

  @type t :: %__MODULE__{
          sessions: %{optional(binary()) => session()}
        }

  @enforce_keys [:sessions]
  defstruct [:sessions]

  @spec new() :: t()
  def new, do: %__MODULE__{sessions: %{}}

  @spec have_open_session?(t()) :: boolean()
  def have_open_session?(%__MODULE__{sessions: sessions}) do
    Enum.any?(sessions, fn {_key, session} -> session.index_info.closed == nil end)
  end

  @spec get_open_session(t()) :: {binary(), session()} | nil
  def get_open_session(%__MODULE__{sessions: sessions}) do
    Enum.find(sessions, fn {_key, session} -> session.index_info.closed == nil end)
  end

  @spec get_session(t(), binary()) :: session() | nil
  def get_session(%__MODULE__{sessions: sessions}, base_key) do
    Map.get(sessions, base_key)
  end

  @spec put_session(t(), binary(), session()) :: t()
  def put_session(%__MODULE__{sessions: sessions} = record, base_key, session) do
    %{record | sessions: Map.put(sessions, base_key, session)}
  end

  @spec close_session(t(), binary(), keyword()) :: t()
  def close_session(%__MODULE__{sessions: sessions} = record, base_key, opts \\ []) do
    case Map.get(sessions, base_key) do
      nil ->
        record

      session ->
        closed_session =
          put_in(session.index_info.closed, Keyword.get_lazy(opts, :closed_at, &now_ms/0))

        updated_sessions =
          sessions
          |> Map.put(base_key, closed_session)
          |> trim_closed_sessions()

        %{record | sessions: updated_sessions}
    end
  end

  @spec close_open_session(t(), keyword()) :: t()
  def close_open_session(%__MODULE__{} = record, opts \\ []) do
    case get_open_session(record) do
      {base_key, _session} -> close_session(record, base_key, opts)
      nil -> record
    end
  end

  @spec empty?(t()) :: boolean()
  def empty?(%__MODULE__{sessions: sessions}), do: map_size(sessions) == 0

  defp trim_closed_sessions(sessions) when map_size(sessions) <= @max_closed_sessions + 1 do
    sessions
  end

  defp trim_closed_sessions(sessions) do
    # Keep the open session + most recent @max_closed_sessions closed ones
    {open, closed} =
      Enum.split_with(sessions, fn {_key, session} -> session.index_info.closed == nil end)

    kept_closed =
      closed
      |> Enum.sort_by(fn {_key, session} -> session.index_info.closed end, :desc)
      |> Enum.take(@max_closed_sessions)

    Map.new(open ++ kept_closed)
  end

  defp now_ms, do: System.system_time(:millisecond)
end
