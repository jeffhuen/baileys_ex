defmodule BaileysEx.Connection.Config do
  @moduledoc """
  Connection configuration defaults and platform mapping.
  """

  @type browser :: {String.t(), String.t(), String.t()}
  @type platform ::
          :CHROME
          | :FIREFOX
          | :SAFARI
          | :EDGE
          | :OPERA
          | :DESKTOP
          | :DARWIN
          | :WIN32
          | :LINUX
          | :UNKNOWN

  @type t :: %__MODULE__{
          ws_url: String.t(),
          keep_alive_interval_ms: pos_integer(),
          retry_delay_ms: pos_integer(),
          max_retries: non_neg_integer(),
          connect_timeout_ms: pos_integer(),
          browser: browser(),
          print_qr_in_terminal: boolean()
        }

  @platforms %{
    "Chrome" => :CHROME,
    "Firefox" => :FIREFOX,
    "Safari" => :SAFARI,
    "Edge" => :EDGE,
    "Opera" => :OPERA,
    "Desktop" => :DESKTOP,
    "Mac OS" => :DARWIN,
    "Windows" => :WIN32,
    "Linux" => :LINUX
  }

  defstruct ws_url: "wss://web.whatsapp.com/ws/chat",
            keep_alive_interval_ms: 25_000,
            retry_delay_ms: 2_000,
            max_retries: 5,
            connect_timeout_ms: 20_000,
            browser: {"BaileysEx", "Chrome", "0.1.0"},
            print_qr_in_terminal: false

  @spec new(keyword()) :: t()
  def new(opts \\ []) when is_list(opts), do: struct(__MODULE__, opts)

  @spec platform_type(String.t()) :: platform()
  def platform_type(browser_name) when is_binary(browser_name) do
    Map.get(@platforms, browser_name, :UNKNOWN)
  end
end
