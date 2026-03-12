defmodule BaileysEx.Message.Decode do
  @moduledoc """
  Envelope decode helpers aligned with Baileys' message addressing rules.
  """

  alias BaileysEx.BinaryNode
  alias BaileysEx.Protocol.JID, as: JIDUtil
  alias BaileysEx.Signal.Repository

  @type context :: %{
          required(:signal_repository) => Repository.t(),
          required(:me_id) => String.t(),
          optional(:me_lid) => String.t(),
          optional(atom()) => term()
        }

  @type envelope :: %{
          required(:remote_jid) => String.t(),
          optional(:remote_jid_alt) => String.t(),
          optional(:participant) => String.t(),
          optional(:participant_alt) => String.t(),
          optional(:server_id) => String.t(),
          required(:from_me) => boolean(),
          required(:author_jid) => String.t(),
          required(:decryption_jid) => String.t(),
          required(:addressing_mode) => :pn | :lid
        }

  @spec decode_envelope(BinaryNode.t(), context()) ::
          {:ok, envelope(), context()} | {:error, term()}
  def decode_envelope(
        %BinaryNode{attrs: attrs} = node,
        %{signal_repository: %Repository{} = repo} = context
      ) do
    from = attrs["from"]
    participant = attrs["participant"]
    recipient = attrs["recipient"]
    me_lid = context[:me_lid]

    with true <- is_binary(from) or {:error, :missing_sender},
         addressing_context <- extract_addressing_context(node),
         {:ok, repo, decryption_jid} <- resolve_decryption_jid(participant || from, repo),
         {:ok, envelope} <-
           build_envelope(
             from,
             participant,
             recipient,
             context.me_id,
             me_lid,
             decryption_jid,
             addressing_context,
             attrs["server_id"]
           ) do
      {:ok, envelope, %{context | signal_repository: repo}}
    end
  end

  def extract_addressing_context(%BinaryNode{attrs: attrs}) do
    sender = attrs["participant"] || attrs["from"]
    addressing_mode = addressing_mode(attrs["addressing_mode"], sender)
    {sender_alt, recipient_alt} = alternate_addresses(addressing_mode, attrs)

    %{
      addressing_mode: addressing_mode,
      sender_alt: sender_alt,
      recipient_alt: recipient_alt
    }
  end

  defp build_envelope(
         from,
         participant,
         recipient,
         me_id,
         me_lid,
         decryption_jid,
         addressing,
         server_id
       ) do
    case sender_kind(from) do
      :direct ->
        {:ok,
         direct_envelope(from, participant, recipient, me_id, me_lid, decryption_jid, addressing)}

      :group ->
        grouped_envelope(from, participant, me_id, me_lid, decryption_jid, addressing)

      :broadcast ->
        grouped_envelope(from, participant, me_id, me_lid, decryption_jid, addressing)

      :newsletter ->
        {:ok, newsletter_envelope(from, me_id, me_lid, decryption_jid, addressing, server_id)}

      :unsupported ->
        {:error, {:unsupported_sender, from}}
    end
  end

  defp resolve_decryption_jid(sender, %Repository{} = repo) do
    if JIDUtil.lid?(sender) or JIDUtil.hosted_lid?(sender) do
      {:ok, repo, sender}
    else
      with {:ok, repo, mapped_lid} <- Repository.get_lid_for_pn(repo, sender) do
        {:ok, repo, mapped_lid || sender}
      end
    end
  end

  defp addressing_mode("lid", _sender), do: :lid
  defp addressing_mode("pn", _sender), do: :pn
  defp addressing_mode(_mode, sender), do: infer_addressing_mode(sender)

  defp alternate_addresses(:lid, attrs) do
    {
      attrs["participant_pn"] || attrs["sender_pn"] || attrs["peer_recipient_pn"],
      attrs["recipient_pn"]
    }
  end

  defp alternate_addresses(:pn, attrs) do
    {
      attrs["participant_lid"] || attrs["sender_lid"] || attrs["peer_recipient_lid"],
      attrs["recipient_lid"]
    }
  end

  defp sender_kind(from) do
    cond do
      JIDUtil.user?(from) or JIDUtil.lid?(from) or JIDUtil.hosted_pn?(from) or
          JIDUtil.hosted_lid?(from) ->
        :direct

      JIDUtil.group?(from) ->
        :group

      JIDUtil.broadcast?(from) ->
        :broadcast

      JIDUtil.newsletter?(from) ->
        :newsletter

      true ->
        :unsupported
    end
  end

  defp direct_envelope(
         from,
         participant,
         recipient,
         me_id,
         me_lid,
         decryption_jid,
         %{addressing_mode: addressing_mode, sender_alt: sender_alt}
       ) do
    {remote_jid, from_me} =
      if recipient && same_user?(from, me_id, me_lid) do
        {recipient, true}
      else
        {from, false}
      end

    %{
      remote_jid: remote_jid,
      remote_jid_alt: sender_alt,
      participant: participant,
      from_me: from_me,
      author_jid: from,
      decryption_jid: decryption_jid,
      addressing_mode: addressing_mode
    }
  end

  defp grouped_envelope(
         from,
         participant,
         me_id,
         me_lid,
         decryption_jid,
         %{addressing_mode: addressing_mode, sender_alt: sender_alt}
       ) do
    if is_binary(participant) do
      {:ok,
       %{
         remote_jid: from,
         participant: participant,
         participant_alt: sender_alt,
         from_me: same_user?(participant, me_id, me_lid),
         author_jid: participant,
         decryption_jid: decryption_jid,
         addressing_mode: addressing_mode
       }}
    else
      {:error, :missing_participant}
    end
  end

  defp newsletter_envelope(
         from,
         me_id,
         me_lid,
         decryption_jid,
         %{addressing_mode: addressing_mode},
         server_id
       ) do
    %{
      remote_jid: from,
      from_me: same_user?(from, me_id, me_lid),
      author_jid: from,
      decryption_jid: decryption_jid,
      addressing_mode: addressing_mode,
      server_id: server_id
    }
  end

  defp infer_addressing_mode(sender) do
    if JIDUtil.lid?(sender) or JIDUtil.hosted_lid?(sender), do: :lid, else: :pn
  end

  defp same_user?(nil, _me_id, _me_lid), do: false

  defp same_user?(jid, me_id, me_lid) do
    JIDUtil.same_user?(jid, me_id) || (is_binary(me_lid) && JIDUtil.same_user?(jid, me_lid))
  end
end
