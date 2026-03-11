defmodule BaileysEx.Connection.Config do
  @moduledoc """
  Connection configuration defaults and platform mapping.
  """

  @type browser :: {String.t(), String.t(), String.t()}
  @type version :: [non_neg_integer()]
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
          default_query_timeout_ms: pos_integer(),
          initial_sync_timeout_ms: pos_integer(),
          retry_delay_ms: pos_integer(),
          max_retries: non_neg_integer(),
          connect_timeout_ms: pos_integer(),
          fire_init_queries: boolean(),
          mark_online_on_connect: boolean(),
          browser: browser(),
          version: version(),
          country_code: String.t(),
          sync_full_history: boolean(),
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

  @device_props_platform_types %{
    "CHROME" => 1,
    "FIREFOX" => 2,
    "IE" => 3,
    "OPERA" => 4,
    "SAFARI" => 5,
    "EDGE" => 6,
    "DESKTOP" => 7
  }

  @web_sub_platforms %{
    "Mac OS" => 3,
    "Windows" => 4
  }

  defstruct ws_url: "wss://web.whatsapp.com/ws/chat",
            keep_alive_interval_ms: 25_000,
            default_query_timeout_ms: 60_000,
            initial_sync_timeout_ms: 20_000,
            retry_delay_ms: 2_000,
            max_retries: 5,
            connect_timeout_ms: 20_000,
            fire_init_queries: true,
            mark_online_on_connect: true,
            browser: {"Mac OS", "Chrome", "14.4.1"},
            version: [2, 3000, 1_033_846_690],
            country_code: "US",
            sync_full_history: true,
            print_qr_in_terminal: false

  @spec new(keyword()) :: t()
  def new(opts \\ []) when is_list(opts), do: struct(__MODULE__, opts)

  @spec platform_type(String.t()) :: platform()
  def platform_type(browser_name) when is_binary(browser_name) do
    Map.get(@platforms, browser_name, :UNKNOWN)
  end

  @spec platform_id(String.t()) :: String.t()
  def platform_id(browser_name) when is_binary(browser_name) do
    browser_name
    |> device_props_platform_type()
    |> Integer.to_string()
  end

  @spec device_props_platform_type(String.t()) :: non_neg_integer()
  def device_props_platform_type(browser_name) when is_binary(browser_name) do
    browser_name
    |> String.upcase()
    |> then(&Map.get(@device_props_platform_types, &1, 1))
  end

  @spec web_sub_platform(t()) :: non_neg_integer()
  def web_sub_platform(%__MODULE__{
        sync_full_history: true,
        browser: {platform_name, "Desktop", _platform_version}
      }) do
    Map.get(@web_sub_platforms, platform_name, 0)
  end

  def web_sub_platform(%__MODULE__{}), do: 0
end
