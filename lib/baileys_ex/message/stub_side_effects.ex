defmodule BaileysEx.Message.StubSideEffects do
  @moduledoc """
  Pure reducer that derives higher-level side-effect events from group stub messages.

  Baileys' `processMessage` (process-message.ts, lines 513-614) translates stub
  message types into events like `group-participants.update`, `groups.update`,
  `group.join-request`, and chat `readOnly` flips. This module ports that logic
  as a stateless function: given a stub payload, return a list of side-effect
  tuples that the caller can emit through the EventEmitter.

  ## Input

  A map with the following keys:

    * `:stub_type` - atom stub type (e.g., `:GROUP_PARTICIPANT_ADD`)
    * `:stub_parameters` - list of string parameters (JSON-encoded participants, etc.)
    * `:group_jid` - the group's JID string
    * `:author` - the JID of the action author (participant attribute)
    * `:author_pn` - the PN (phone number) alternative for the author
    * `:me_id` - the current user's JID, used for `readOnly` flip detection

  ## Output

  A list of tagged tuples:

    * `{:group_participants_update, payload}` — participant action event
    * `{:groups_update, [update]}` — group metadata change event
    * `{:group_join_request, payload}` — join request event
    * `{:chats_update, [update]}` — chat read-only flip
  """

  alias BaileysEx.Protocol.JID, as: JIDUtil

  @type stub_input :: %{
          stub_type: atom() | nil,
          stub_parameters: [String.t()],
          group_jid: String.t(),
          author: String.t() | nil,
          author_pn: String.t() | nil,
          me_id: String.t()
        }

  @type side_effect ::
          {:group_participants_update, map()}
          | {:groups_update, [map()]}
          | {:group_join_request, map()}
          | {:chats_update, [map()]}

  @doc """
  Derive side-effect events from a group stub message payload.

  Returns a list of side-effect tuples that should be emitted via EventEmitter.
  Returns an empty list for unrecognized or nil stub types.
  """
  @spec derive(stub_input()) :: [side_effect()]
  def derive(%{stub_type: nil}), do: []

  # Participant change number -> modify
  def derive(%{stub_type: :GROUP_PARTICIPANT_CHANGE_NUMBER} = input) do
    participant_effects(input, :modify)
  end

  # Remove / leave -> remove, with readOnly flip
  def derive(%{stub_type: type} = input)
      when type in [:GROUP_PARTICIPANT_LEAVE, :GROUP_PARTICIPANT_REMOVE] do
    effects = participant_effects(input, :remove)

    if participants_include_me?(input) do
      effects ++ [{:chats_update, [%{id: input.group_jid, read_only: true}]}]
    else
      effects
    end
  end

  # Add / invite / add-request-join -> add, with readOnly flip
  def derive(%{stub_type: type} = input)
      when type in [
             :GROUP_PARTICIPANT_ADD,
             :GROUP_PARTICIPANT_INVITE,
             :GROUP_PARTICIPANT_ADD_REQUEST_JOIN
           ] do
    effects = participant_effects(input, :add)

    if participants_include_me?(input) do
      effects ++ [{:chats_update, [%{id: input.group_jid, read_only: false}]}]
    else
      effects
    end
  end

  # Demote
  def derive(%{stub_type: :GROUP_PARTICIPANT_DEMOTE} = input) do
    participant_effects(input, :demote)
  end

  # Promote
  def derive(%{stub_type: :GROUP_PARTICIPANT_PROMOTE} = input) do
    participant_effects(input, :promote)
  end

  # Group change announce — Baileys maps both "announcement" and "not_announcement"
  # tags to GROUP_CHANGE_ANNOUNCE with "on"/"off" parameter distinguishing the value
  def derive(%{stub_type: :GROUP_CHANGE_ANNOUNCE} = input) do
    value = first_param(input)
    group_update_effects(input, %{announce: value in ["true", "on"]})
  end

  # Group change restrict — Baileys maps both "locked" and "unlocked" tags to
  # GROUP_CHANGE_RESTRICT with "on"/"off" parameter distinguishing the value
  def derive(%{stub_type: :GROUP_CHANGE_RESTRICT} = input) do
    value = first_param(input)
    group_update_effects(input, %{restrict: value in ["true", "on"]})
  end

  # Group change subject — emits both groups_update and chats_update (Baileys: chat.name)
  def derive(%{stub_type: :GROUP_CHANGE_SUBJECT} = input) do
    name = first_param(input)

    group_update_effects(input, %{subject: name}) ++
      [{:chats_update, [%{id: input.group_jid, name: name}]}]
  end

  # Group change description — emits both groups_update and chats_update (Baileys: chat.description)
  def derive(%{stub_type: :GROUP_CHANGE_DESCRIPTION} = input) do
    description = first_param(input)

    group_update_effects(input, %{desc: description}) ++
      [{:chats_update, [%{id: input.group_jid, description: description}]}]
  end

  # Group change invite link
  def derive(%{stub_type: :GROUP_CHANGE_INVITE_LINK} = input) do
    code = first_param(input)
    group_update_effects(input, %{invite_code: code})
  end

  # Group member add mode
  def derive(%{stub_type: :GROUP_MEMBER_ADD_MODE} = input) do
    value = first_param(input)
    group_update_effects(input, %{member_add_mode: value == "all_member_add"})
  end

  # Group membership join approval mode
  def derive(%{stub_type: :GROUP_MEMBERSHIP_JOIN_APPROVAL_MODE} = input) do
    value = first_param(input)
    group_update_effects(input, %{join_approval_mode: value == "on"})
  end

  # Group membership join approval request (non-admin add)
  def derive(%{stub_type: :GROUP_MEMBERSHIP_JOIN_APPROVAL_REQUEST_NON_ADMIN_ADD} = input) do
    params = input.stub_parameters || []

    with [participant_json | rest] <- params,
         {:ok, participant_data} <- JSON.decode(participant_json) do
      action = Enum.at(rest, 0)
      method = Enum.at(rest, 1)

      [
        {:group_join_request,
         %{
           id: input.group_jid,
           author: input.author,
           author_pn: input.author_pn,
           participant: participant_data["lid"],
           participant_pn: participant_data["pn"],
           action: action,
           method: method
         }}
      ]
    else
      _ -> []
    end
  end

  # Catch-all for unrecognized stub types
  def derive(%{stub_type: _}), do: []

  # -- Private helpers --

  @spec participant_effects(stub_input(), atom()) :: [side_effect()]
  defp participant_effects(input, action) do
    participants = parse_participants(input.stub_parameters || [])

    [
      {:group_participants_update,
       %{
         id: input.group_jid,
         author: input.author,
         author_pn: input.author_pn,
         participants: participants,
         action: action
       }}
    ]
  end

  @spec group_update_effects(stub_input(), map()) :: [side_effect()]
  defp group_update_effects(input, update) do
    base = %{id: input.group_jid}

    base =
      if input.author do
        Map.put(base, :author, input.author)
      else
        base
      end

    base =
      if input.author_pn do
        Map.put(base, :author_pn, input.author_pn)
      else
        base
      end

    [{:groups_update, [Map.merge(base, update)]}]
  end

  @spec parse_participants([String.t()]) :: [map()]
  defp parse_participants(params) do
    Enum.flat_map(params, fn param ->
      case JSON.decode(param) do
        {:ok, parsed} when is_map(parsed) -> [parsed]
        _ -> []
      end
    end)
  end

  @spec participants_include_me?(stub_input()) :: boolean()
  defp participants_include_me?(input) do
    me_id = input.me_id
    participants = parse_participants(input.stub_parameters || [])

    Enum.any?(participants, fn participant ->
      phone_number = participant["phone_number"] || participant["id"]
      JIDUtil.same_user?(me_id, phone_number)
    end)
  end

  @spec first_param(stub_input()) :: String.t() | nil
  defp first_param(%{stub_parameters: [first | _]}), do: first
  defp first_param(_), do: nil
end
