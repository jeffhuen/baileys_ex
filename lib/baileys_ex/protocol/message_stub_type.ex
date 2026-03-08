defmodule BaileysEx.Protocol.MessageStubType do
  @moduledoc """
  Group notification stub types for synthetic messages.

  Maps string stub type identifiers from WhatsApp group notifications to
  descriptive atoms for pattern matching in the message receiver.
  """

  @stub_types %{
    "create" => :GROUP_CREATE,
    "ephemeral" => :GROUP_CHANGE_EPHEMERAL_SETTING,
    "not_ephemeral" => :GROUP_CHANGE_NOT_EPHEMERAL,
    "modify" => :GROUP_CHANGE_SUBJECT,
    "promote" => :GROUP_PARTICIPANT_PROMOTE,
    "demote" => :GROUP_PARTICIPANT_DEMOTE,
    "remove" => :GROUP_PARTICIPANT_REMOVE,
    "add" => :GROUP_PARTICIPANT_ADD,
    "leave" => :GROUP_PARTICIPANT_LEAVE,
    "subject" => :GROUP_CHANGE_SUBJECT,
    "description" => :GROUP_CHANGE_DESCRIPTION,
    "announcement" => :GROUP_CHANGE_ANNOUNCE,
    "not_announcement" => :GROUP_CHANGE_NOT_ANNOUNCE,
    "locked" => :GROUP_CHANGE_RESTRICT,
    "unlocked" => :GROUP_CHANGE_NOT_RESTRICT,
    "invite" => :GROUP_PARTICIPANT_INVITE,
    "member_add_mode" => :GROUP_MEMBER_ADD_MODE,
    "membership_approval_mode" => :GROUP_MEMBERSHIP_JOIN_APPROVAL_MODE,
    "created_membership_requests" => :GROUP_MEMBERSHIP_JOIN_APPROVAL_REQUEST_NON_ADMIN_ADD,
    "revoked_membership_requests" => :GROUP_MEMBERSHIP_JOIN_APPROVAL_REQUEST_NON_ADMIN_ADD
  }

  @doc """
  Convert a string stub type to its atom representation.

  Returns `nil` if the stub type is not recognized.
  """
  @spec from_string(String.t()) :: atom() | nil
  def from_string(type), do: Map.get(@stub_types, type)

  @doc "Return all known stub type atoms."
  @spec all_types() :: [atom()]
  def all_types, do: Map.values(@stub_types)

  @doc "Return the full mapping of string keys to atom values."
  @spec all() :: %{String.t() => atom()}
  def all, do: @stub_types
end
