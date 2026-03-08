defmodule BaileysEx.Signal.Address do
  @moduledoc """
  Signal protocol address derived from a WhatsApp JID.

  Matches the Baileys `jidToSignalProtocolAddress()` naming rules:
  non-WhatsApp domains are encoded as `user_domainType`, and the device number
  defaults to `0`.
  """

  alias BaileysEx.Protocol.JID

  @type t :: %__MODULE__{
          name: String.t(),
          device_id: non_neg_integer()
        }

  @type error :: :invalid_signal_address

  @enforce_keys [:name, :device_id]
  defstruct [:name, :device_id]

  @whatsapp_servers MapSet.new(["s.whatsapp.net", "c.us", "lid", "hosted", "hosted.lid"])

  @spec from_jid(String.t()) :: {:ok, t()} | {:error, error()}
  def from_jid(jid) when is_binary(jid) do
    case JID.parse(jid) do
      %BaileysEx.JID{user: user, server: server, device: device} when is_binary(user) ->
        maybe_build_address(user, server, device)

      _ ->
        {:error, :invalid_signal_address}
    end
  end

  def from_jid(_jid), do: {:error, :invalid_signal_address}

  @spec to_string(t()) :: String.t()
  def to_string(%__MODULE__{name: name, device_id: device_id}), do: "#{name}.#{device_id}"

  @spec build_address(String.t(), String.t(), non_neg_integer() | nil) ::
          {:ok, t()} | {:error, error()}
  defp build_address(_user, server, 99) when server not in ["hosted", "hosted.lid"],
    do: {:error, :invalid_signal_address}

  defp build_address(user, server, device) do
    domain_type = JID.domain_type_for_server(server)
    name = signal_name(user, domain_type)
    {:ok, %__MODULE__{name: name, device_id: device || 0}}
  end

  @spec signal_name(String.t(), non_neg_integer()) :: String.t()
  defp signal_name(user, 0), do: user
  defp signal_name(user, domain_type), do: "#{user}_#{domain_type}"

  @spec maybe_build_address(String.t(), String.t(), non_neg_integer() | nil) ::
          {:ok, t()} | {:error, error()}
  defp maybe_build_address(user, server, device) do
    if MapSet.member?(@whatsapp_servers, server) do
      build_address(user, server, device)
    else
      {:error, :invalid_signal_address}
    end
  end
end

defimpl String.Chars, for: BaileysEx.Signal.Address do
  @spec to_string(BaileysEx.Signal.Address.t()) :: String.t()
  def to_string(address), do: BaileysEx.Signal.Address.to_string(address)
end
