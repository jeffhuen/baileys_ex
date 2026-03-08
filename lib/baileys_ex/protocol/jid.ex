defmodule BaileysEx.Protocol.JID do
  @moduledoc """
  JID (Jabber ID) parsing, formatting, and utility functions for WhatsApp addressing.

  Handles all WhatsApp JID formats including users, groups, broadcasts, LID
  (Logical Device ID) addresses, newsletters, and device-specific addresses.
  """

  alias BaileysEx.JID
  alias BaileysEx.Protocol.Constants

  @s_whatsapp_net "s.whatsapp.net"
  @g_us "g.us"
  @broadcast "broadcast"
  @lid "lid"
  @newsletter "newsletter"
  @c_us "c.us"
  @hosted "hosted"
  @hosted_lid "hosted.lid"

  @spec s_whatsapp_net() :: String.t()
  def s_whatsapp_net, do: @s_whatsapp_net

  @spec g_us() :: String.t()
  def g_us, do: @g_us

  @spec broadcast() :: String.t()
  def broadcast, do: @broadcast

  @spec lid() :: String.t()
  def lid, do: @lid

  @spec newsletter() :: String.t()
  def newsletter, do: @newsletter

  @doc """
  Parse a JID string into a `BaileysEx.JID` struct.

  Handles formats:
  - `"user@server"` — basic JID
  - `"user:device@server"` — JID with device ID
  - `"user_agent:device@server"` — JID with agent and device
  - `"@server"` — server-only JID (nil user)

  Returns `nil` if the string has no `@` separator.
  """
  @spec parse(String.t() | nil) :: JID.t() | nil
  def parse(nil), do: nil
  def parse(""), do: nil

  def parse(jid_string) when is_binary(jid_string) do
    case String.split(jid_string, "@", parts: 2) do
      [_no_server] ->
        nil

      [user_combined, server] ->
        {user, device, agent} = parse_user_part(user_combined)
        %JID{user: user, server: server, device: device, agent: agent}
    end
  end

  defp parse_user_part(""), do: {nil, nil, nil}

  defp parse_user_part(user_combined) do
    {user_agent, device} =
      case String.split(user_combined, ":", parts: 2) do
        [ua, d] -> {ua, String.to_integer(d)}
        [ua] -> {ua, nil}
      end

    {user, agent} =
      case String.split(user_agent, "_", parts: 2) do
        [u, a] -> {u, String.to_integer(a)}
        [u] -> {u, nil}
      end

    {user, device, agent}
  end

  @doc """
  Format a JID struct back to its string representation.

  Produces `"user_agent:device@server"` format, omitting agent and device
  parts when they are nil or 0.
  """
  @spec to_string(JID.t()) :: String.t()
  def to_string(%JID{} = jid) do
    jid_encode(jid.user, jid.server, jid.device, jid.agent)
  end

  @doc """
  Construct a JID string from component parts.

  Follows Baileys `jidEncode` convention:
  - Agent is appended as `_agent` suffix on user
  - Device is appended as `:device` suffix
  - Result: `"user_agent:device@server"`
  """
  @spec jid_encode(String.t() | nil, String.t(), non_neg_integer() | nil, non_neg_integer() | nil) ::
          String.t()
  def jid_encode(user, server, device \\ nil, agent \\ nil) do
    user_part = user || ""

    user_part =
      if agent && agent != 0 do
        "#{user_part}_#{agent}"
      else
        user_part
      end

    user_part =
      if device && device != 0 do
        "#{user_part}:#{device}"
      else
        user_part
      end

    "#{user_part}@#{server}"
  end

  @doc "Check if JID represents a group."
  @spec group?(JID.t() | String.t() | nil) :: boolean()
  def group?(%JID{server: @g_us}), do: true
  def group?(%JID{}), do: false
  def group?(jid) when is_binary(jid), do: String.ends_with?(jid, "@g.us")
  def group?(_), do: false

  @doc "Check if JID represents a user (on s.whatsapp.net)."
  @spec user?(JID.t() | String.t() | nil) :: boolean()
  def user?(%JID{server: @s_whatsapp_net}), do: true
  def user?(%JID{}), do: false
  def user?(jid) when is_binary(jid), do: String.ends_with?(jid, "@s.whatsapp.net")
  def user?(_), do: false

  @doc "Check if JID represents a broadcast."
  @spec broadcast?(JID.t() | String.t() | nil) :: boolean()
  def broadcast?(%JID{server: @broadcast}), do: true
  def broadcast?(%JID{}), do: false
  def broadcast?(jid) when is_binary(jid), do: String.ends_with?(jid, "@broadcast")
  def broadcast?(_), do: false

  @doc "Check if JID represents a newsletter."
  @spec newsletter?(JID.t() | String.t() | nil) :: boolean()
  def newsletter?(%JID{server: @newsletter}), do: true
  def newsletter?(%JID{}), do: false
  def newsletter?(jid) when is_binary(jid), do: String.ends_with?(jid, "@newsletter")
  def newsletter?(_), do: false

  @doc "Detect the addressing mode from a JID."
  @spec addressing_mode(JID.t()) :: :lid | :pn
  def addressing_mode(%JID{server: @lid}), do: :lid
  def addressing_mode(%JID{}), do: :pn

  @doc "Check if JID is a LID (Logical Device ID)."
  @spec lid?(JID.t() | String.t() | nil) :: boolean()
  def lid?(%JID{server: @lid}), do: true
  def lid?(%JID{}), do: false
  def lid?(jid) when is_binary(jid), do: String.ends_with?(jid, "@lid")
  def lid?(_), do: false

  @doc "Check if JID is a hosted PN."
  @spec hosted_pn?(JID.t() | String.t() | nil) :: boolean()
  def hosted_pn?(%JID{server: @hosted}), do: true
  def hosted_pn?(%JID{}), do: false
  def hosted_pn?(jid) when is_binary(jid), do: String.ends_with?(jid, "@hosted")
  def hosted_pn?(_), do: false

  @doc "Check if JID is a hosted LID."
  @spec hosted_lid?(JID.t() | String.t() | nil) :: boolean()
  def hosted_lid?(%JID{server: @hosted_lid}), do: true
  def hosted_lid?(%JID{}), do: false
  def hosted_lid?(jid) when is_binary(jid), do: String.ends_with?(jid, "@hosted.lid")
  def hosted_lid?(_), do: false

  @doc "Check if JID is the status broadcast."
  @spec status_broadcast?(JID.t() | String.t()) :: boolean()
  def status_broadcast?(%JID{user: "status", server: @broadcast}), do: true
  def status_broadcast?(%JID{}), do: false
  def status_broadcast?(jid) when is_binary(jid), do: jid == "status@broadcast"

  @doc """
  Normalize a JID for comparison.

  Strips device info and normalizes c.us to s.whatsapp.net.
  """
  @spec normalized_user(String.t() | nil) :: String.t()
  def normalized_user(nil), do: ""

  def normalized_user(jid) when is_binary(jid) do
    case parse(jid) do
      nil ->
        ""

      %JID{user: user, server: server} ->
        normalized_server = if server == @c_us, do: @s_whatsapp_net, else: server
        jid_encode(user, normalized_server)
    end
  end

  @doc """
  Check if two JIDs belong to the same user (ignoring device).
  """
  @spec same_user?(String.t() | nil, String.t() | nil) :: boolean()
  def same_user?(jid1, jid2) do
    case {parse(jid1), parse(jid2)} do
      {%JID{user: u1}, %JID{user: u2}} when not is_nil(u1) and not is_nil(u2) -> u1 == u2
      _ -> false
    end
  end

  @doc """
  Normalize JID for Signal protocol addressing.

  Strips device number, keeps user and server.
  """
  @spec to_signal_address(JID.t()) :: JID.t()
  def to_signal_address(%JID{} = jid) do
    %JID{jid | device: nil, agent: nil}
  end

  @doc """
  Get the domain type byte for AD_JID encoding based on server.
  """
  @spec domain_type_for_server(String.t()) :: non_neg_integer()
  def domain_type_for_server(@lid), do: Constants.wajid_domain(:lid)
  def domain_type_for_server("hosted"), do: Constants.wajid_domain(:hosted)
  def domain_type_for_server("hosted.lid"), do: Constants.wajid_domain(:hosted_lid)
  def domain_type_for_server(_), do: Constants.wajid_domain(:whatsapp)

  @doc """
  Get the server string from a domain type byte.
  """
  @spec server_from_domain_type(non_neg_integer(), String.t()) :: String.t()
  def server_from_domain_type(1, _default), do: @lid
  def server_from_domain_type(128, _default), do: "hosted"
  def server_from_domain_type(129, _default), do: "hosted.lid"
  def server_from_domain_type(_, default), do: default
end
