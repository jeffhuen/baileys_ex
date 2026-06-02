defmodule BaileysEx.Auth.QR do
  @moduledoc false

  alias BaileysEx.Connection.Config

  @linked_devices_url "https://wa.me/settings/linked_devices#"

  @companion_web_clients %{
    "Chrome" => 1,
    "Edge" => 2,
    "Firefox" => 3,
    "IE" => 4,
    "Opera" => 5,
    "Safari" => 6
  }

  @spec generate(binary(), map()) :: binary()
  def generate(ref, auth_state), do: generate(ref, auth_state, Config.new())

  @spec generate(binary(), map(), Config.t() | Config.browser()) :: binary()
  def generate(ref, auth_state, browser_or_config)
      when is_binary(ref) and is_map(auth_state) do
    data =
      [
        ref,
        Base.encode64(fetch_public_key!(auth_state, :noise_key)),
        Base.encode64(fetch_public_key!(auth_state, :signed_identity_key)),
        Base.encode64(fetch_adv_secret!(auth_state)),
        companion_platform_id(browser_or_config)
      ]
      |> Enum.join(",")

    @linked_devices_url <> data
  end

  @spec companion_platform_id(Config.t() | Config.browser()) :: String.t()
  def companion_platform_id(%Config{browser: browser}), do: companion_platform_id(browser)

  def companion_platform_id({os, "Desktop", _version}) do
    if os == "Windows", do: "8", else: "7"
  end

  def companion_platform_id({_os, browser_name, _version}) when is_binary(browser_name) do
    @companion_web_clients
    |> Map.get(browser_name, 9)
    |> Integer.to_string()
  end

  defp fetch_public_key!(auth_state, key_name) do
    case Map.get(auth_state, key_name) do
      %{public: public_key} when is_binary(public_key) -> public_key
      _ -> raise ArgumentError, "missing #{key_name} public key"
    end
  end

  defp fetch_adv_secret!(%{adv_secret_key: <<_::binary-size(32)>> = adv_secret_key}),
    do: adv_secret_key

  defp fetch_adv_secret!(%{adv_secret_key: adv_secret_key}) when is_binary(adv_secret_key) do
    case Base.decode64(adv_secret_key) do
      {:ok, <<_::binary-size(32)>> = decoded} -> decoded
      _ -> raise ArgumentError, "invalid adv_secret_key"
    end
  end

  defp fetch_adv_secret!(_auth_state), do: raise(ArgumentError, "missing adv_secret_key")
end
