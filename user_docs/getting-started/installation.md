# Installation

You will finish this page with BaileysEx compiled in your project and ready for a real WhatsApp connection.

## Before you begin

- Elixir 1.19 or newer
- OTP 28
- A Rust toolchain available on your machine
- A WhatsApp account you can pair with a companion client

## Steps

### 1. Add BaileysEx to your dependencies

Add BaileysEx to your `mix.exs` dependencies.

```elixir
defp deps do
  [
    {:baileys_ex, "~> 0.1.0-alpha.1"}
  ]
end
```

BaileysEx builds native code during compilation, so you need Rust on the machine that runs `mix compile`.
Because the current public release is an alpha prerelease, the prerelease version must be requested explicitly.

### 2. Fetch and compile the project

Run the normal Mix setup commands.

```bash
mix deps.get
mix compile
```

You should see: `Generated baileys_ex app`

### 3. Pick a transport and an auth-state path

BaileysEx does not open a network connection unless you pass a transport. The standard choice is `BaileysEx.Connection.Transport.MintWebSocket`.

```elixir
alias BaileysEx.Connection.Transport.MintWebSocket

transport = {MintWebSocket, []}
auth_path = "tmp/baileys_auth"
```

You reuse the same auth path across restarts so you do not need to pair every time.

## Check that it worked

Start `iex -S mix` and load credentials once:

```elixir
alias BaileysEx.Auth.FilePersistence

{:ok, auth_state} = FilePersistence.load_credentials("tmp/baileys_auth")
```

You should get a `BaileysEx.Auth.State` struct back, even the first time.

---

**Next steps:**
- [First Connection](first-connection.md) — start the runtime and pair with WhatsApp
- [Configuration Reference](../reference/configuration.md) — review the public connection and runtime options
