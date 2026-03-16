defmodule BaileysEx.WAM.Definitions do
  @moduledoc """
  Loads the generated WAM event and global definitions derived from Baileys rc9.
  """

  @external_resource Path.expand("../../../priv/wam/definitions.json", __DIR__)
  @persistent_key {__MODULE__, :definitions}

  @type prop_definition :: %{id: non_neg_integer(), type: term()}
  @type event_definition :: %{
          id: non_neg_integer(),
          weight: integer(),
          wam_channel: String.t(),
          private_stats_id_int: integer() | nil,
          props: %{optional(String.t()) => prop_definition()}
        }
  @type global_definition :: %{
          id: non_neg_integer(),
          type: term(),
          validator: String.t() | nil,
          channels: [String.t()]
        }

  @doc "Fetch all loaded WAM definitions."
  @spec all() :: %{
          events: %{String.t() => event_definition()},
          globals: %{String.t() => global_definition()}
        }
  def all do
    case :persistent_term.get(@persistent_key, :undefined) do
      :undefined ->
        definitions = load_definitions()
        :persistent_term.put(@persistent_key, definitions)
        definitions

      definitions ->
        definitions
    end
  end

  @doc "Fetch one event definition by name."
  @spec event(String.t() | atom()) :: {:ok, event_definition()} | {:error, :unknown_event}
  def event(name) do
    case Map.fetch(all().events, normalize_name(name)) do
      {:ok, definition} -> {:ok, definition}
      :error -> {:error, :unknown_event}
    end
  end

  @doc "Fetch one event definition by name, raising on unknown names."
  @spec event!(String.t() | atom()) :: event_definition()
  def event!(name) do
    case event(name) do
      {:ok, definition} -> definition
      {:error, :unknown_event} -> raise ArgumentError, "unknown WAM event #{inspect(name)}"
    end
  end

  @doc "Fetch one global definition by name."
  @spec global(String.t() | atom()) :: {:ok, global_definition()} | {:error, :unknown_global}
  def global(name) do
    case Map.fetch(all().globals, normalize_name(name)) do
      {:ok, definition} -> {:ok, definition}
      :error -> {:error, :unknown_global}
    end
  end

  @doc "Fetch one global definition by name, raising on unknown names."
  @spec global!(String.t() | atom()) :: global_definition()
  def global!(name) do
    case global(name) do
      {:ok, definition} -> definition
      {:error, :unknown_global} -> raise ArgumentError, "unknown WAM global #{inspect(name)}"
    end
  end

  defp load_definitions do
    contents =
      :baileys_ex
      |> Application.app_dir("priv/wam/definitions.json")
      |> File.read!()

    %{"events" => events, "globals" => globals} = JSON.decode!(contents)

    %{
      events: Map.new(events, &normalize_event/1),
      globals: Map.new(globals, &normalize_global/1)
    }
  end

  defp normalize_event(event) do
    props =
      event["props"]
      |> Enum.map(fn {name, [id, type]} ->
        {name, %{id: id, type: type}}
      end)
      |> Map.new()

    {event["name"],
     %{
       id: event["id"],
       weight: event["weight"],
       wam_channel: event["wamChannel"],
       private_stats_id_int: event["privateStatsIdInt"],
       props: props
     }}
  end

  defp normalize_global(global) do
    {global["name"],
     %{
       id: global["id"],
       type: global["type"],
       validator: global["validator"],
       channels: global["channels"]
     }}
  end

  defp normalize_name(name) when is_atom(name), do: Atom.to_string(name)
  defp normalize_name(name) when is_binary(name), do: name
end
