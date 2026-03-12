defmodule BaileysEx.Protocol.Proto.VerifiedNameCertificate.Details do
  @moduledoc false

  alias BaileysEx.Protocol.Proto.MessageSupport

  defstruct serial: nil, issuer: nil, verified_name: nil

  @type t :: %__MODULE__{
          serial: non_neg_integer() | nil,
          issuer: String.t() | nil,
          verified_name: String.t() | nil
        }

  @spec encode(t()) :: binary()
  def encode(%__MODULE__{} = details) do
    MessageSupport.encode_fields(details,
      serial: {:uint, 1},
      issuer: {:string, 2},
      verified_name: {:string, 4}
    )
  end

  @spec decode(binary()) :: {:ok, t()} | {:error, term()}
  def decode(binary) do
    MessageSupport.decode_fields(binary, %__MODULE__{},
      serial: {:uint, 1},
      issuer: {:string, 2},
      verified_name: {:string, 4}
    )
  end
end

defmodule BaileysEx.Protocol.Proto.VerifiedNameCertificate do
  @moduledoc false

  alias BaileysEx.Protocol.Proto.MessageSupport

  defstruct details: nil, signature: nil, server_signature: nil

  @type t :: %__MODULE__{
          details: binary() | nil,
          signature: binary() | nil,
          server_signature: binary() | nil
        }

  @spec encode(t()) :: binary()
  def encode(%__MODULE__{} = cert) do
    MessageSupport.encode_fields(cert,
      details: {:bytes, 1},
      signature: {:bytes, 2},
      server_signature: {:bytes, 3}
    )
  end

  @spec decode(binary()) :: {:ok, t()} | {:error, term()}
  def decode(binary) do
    MessageSupport.decode_fields(binary, %__MODULE__{},
      details: {:bytes, 1},
      signature: {:bytes, 2},
      server_signature: {:bytes, 3}
    )
  end
end
