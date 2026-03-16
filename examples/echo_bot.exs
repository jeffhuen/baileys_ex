alias BaileysEx.Auth.FilePersistence
alias BaileysEx.Auth.State
alias BaileysEx.Connection.Transport.MintWebSocket
alias BaileysEx.Protocol.Proto.Message

defmodule EchoBot do
  @moduledoc false

  def main(argv) do
    argv = Enum.drop_while(argv, &(&1 == "--"))

    case OptionParser.parse(argv, strict: [auth_path: :string, help: :boolean]) do
      {opts, _args, _invalid} ->
        if opts[:help] do
          print_help()
        else
          run(opts)
        end
    end
  end

  defp run(opts) do
    auth_path =
      opts[:auth_path] ||
        System.get_env("BAILEYS_ECHO_AUTH_PATH") ||
        Path.expand("tmp/echo_bot_auth", File.cwd!())

    {:ok, auth_state} = FilePersistence.load_credentials(auth_path)

    {:ok, connection} =
      BaileysEx.connect(auth_state,
        transport: {MintWebSocket, []},
        on_qr: fn qr -> IO.puts("Scan QR: #{qr}") end,
        on_connection: fn update -> IO.inspect(update, label: "connection") end
      )

    _unsubscribe =
      BaileysEx.subscribe_raw(connection, fn events ->
        if Map.has_key?(events, :creds_update) do
          persist_auth_state(connection, auth_path)
        end
      end)

    _unsubscribe =
      BaileysEx.subscribe(connection, fn
        {:message, message} ->
          Task.start(fn -> echo_message(connection, message) end)

        _other ->
          :ok
      end)

    IO.puts("Echo bot is running. Press Ctrl+C to exit.")
    Process.sleep(:infinity)
  end

  defp echo_message(_connection, %{key: %{from_me: true}}), do: :ok

  defp echo_message(connection, %{key: %{remote_jid: remote_jid}, message: message}) do
    case extract_text(message) do
      text when is_binary(text) and text != "" ->
        {:ok, _sent} = BaileysEx.send_message(connection, remote_jid, %{text: text})
        :ok

      _ ->
        :ok
    end
  end

  defp echo_message(_connection, _message), do: :ok

  defp extract_text(%Message{conversation: text}) when is_binary(text), do: text

  defp extract_text(%Message{extended_text_message: %Message.ExtendedTextMessage{text: text}})
       when is_binary(text),
       do: text

  defp extract_text(_message), do: nil

  defp persist_auth_state(connection, auth_path) do
    with {:ok, auth_state} <- BaileysEx.auth_state(connection) do
      :ok = FilePersistence.save_credentials(auth_path, coerce_auth_state(auth_state))
    end
  end

  defp coerce_auth_state(%State{} = state), do: state
  defp coerce_auth_state(%{} = state), do: struct(State, state)

  defp print_help do
    IO.puts("""
    Usage:
      mix run examples/echo_bot.exs -- [--auth-path PATH]

    Options:
      --auth-path PATH   Directory for auth persistence
      --help             Show this message

    Environment:
      BAILEYS_ECHO_AUTH_PATH  Default auth directory when --auth-path is omitted
    """)
  end
end

EchoBot.main(System.argv())
