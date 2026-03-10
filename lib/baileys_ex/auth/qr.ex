defmodule BaileysEx.Auth.QR do
  @moduledoc false

  @spec generate(binary(), map()) :: binary()
  def generate(ref, auth_state) when is_binary(ref) and is_map(auth_state) do
    [
      ref,
      Base.encode64(fetch_public_key!(auth_state, :noise_key)),
      Base.encode64(fetch_public_key!(auth_state, :signed_identity_key)),
      Base.encode64(fetch_adv_secret!(auth_state))
    ]
    |> Enum.join(",")
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
