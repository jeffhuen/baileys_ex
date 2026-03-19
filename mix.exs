defmodule BaileysEx.MixProject do
  use Mix.Project

  def project do
    [
      app: :baileys_ex,
      version: "0.1.0-alpha.2",
      description: description(),
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      test_ignore_filters: [~r|^test/support/|],
      deps: deps(),
      homepage_url: "https://github.com/jeffhuen/baileys_ex",
      source_url: "https://github.com/jeffhuen/baileys_ex",
      package: package(),
      docs: docs()
    ]
  end

  def application do
    [
      mod: {BaileysEx.Application, []},
      extra_applications: [:logger, :crypto]
    ]
  end

  defp deps do
    [
      # Rust NIFs (0.37+ has auto NIF discovery, #[derive(Resource)])
      {:rustler, "~> 0.37"},

      # WebSocket
      {:mint_web_socket, "~> 1.0"},
      {:mint, "~> 1.6"},

      # HTTP client (for media upload/download)
      {:req, "~> 0.5"},

      # Protocol Buffers
      {:protox, "~> 1.7"},

      # Telemetry
      {:telemetry, "~> 1.3"},

      # Testing
      {:stream_data, "~> 1.1", only: :test},
      {:mox, "~> 1.2", only: :test},

      # Dev
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end

  defp docs do
    [
      main: "readme",
      warn_missing: [docs: true, moduledocs: true],
      groups_for_modules: [
        "Public API": [BaileysEx],
        Authentication: ~r/^BaileysEx\.Auth/,
        Connection: ~r/^BaileysEx\.Connection/,
        Features: ~r/^BaileysEx\.Feature/,
        Messaging: ~r/^BaileysEx\.Message/,
        Media: ~r/^BaileysEx\.Media/,
        "Signal Protocol": ~r/^BaileysEx\.Signal/,
        Protocol: ~r/^BaileysEx\.Protocol/,
        "App State Sync": ~r/^BaileysEx\.Syncd/,
        "Native NIFs": ~r/^BaileysEx\.Native/,
        Analytics: ~r/^BaileysEx\.WAM/,
        Telemetry: [BaileysEx.Telemetry],
        Utilities: [BaileysEx.Crypto, BaileysEx.Util.LTHash]
      ],
      extras: [
        {"README.md", [title: "BaileysEx"]},
        {"CHANGELOG.md", [title: "Changelog"]},
        {"user_docs/glossary.md", [title: "Glossary"]},
        {"user_docs/getting-started/installation.md", [title: "Installation"]},
        {"user_docs/getting-started/first-connection.md", [title: "First Connection"]},
        {"user_docs/getting-started/sending-your-first-message.md",
         [title: "Send Your First Message"]},
        {"user_docs/guides/messages.md", [title: "Send Messages"]},
        {"user_docs/guides/media.md", [title: "Send and Download Media"]},
        {"user_docs/guides/groups.md", [title: "Work with Groups and Communities"]},
        {"user_docs/guides/presence.md", [title: "Send Presence Updates"]},
        {"user_docs/guides/events-and-subscriptions.md",
         [title: "Event and Subscription Patterns"]},
        {"user_docs/guides/authentication-and-persistence.md",
         [title: "Manage Authentication and Persistence"]},
        {"user_docs/guides/advanced-features.md", [title: "Use Advanced Features"]},
        {"user_docs/guides/manage-app-state-sync.md", [title: "Manage App State Sync"]},
        {"user_docs/reference/configuration.md", [title: "Configuration Reference"]},
        {"user_docs/reference/event-catalog.md", [title: "Event Catalog Reference"]},
        {"user_docs/reference/message-types.md", [title: "Message Types Reference"]},
        {"user_docs/troubleshooting/connection-issues.md",
         [title: "Troubleshooting: Connection Issues"]},
        {"user_docs/troubleshooting/authentication-issues.md",
         [title: "Troubleshooting: Authentication Issues"]},
        {"user_docs/troubleshooting/encryption-issues.md",
         [title: "Troubleshooting: Encryption Issues"]},
        {"user_docs/troubleshooting/app-state-sync-issues.md",
         [title: "Troubleshooting: App State Sync"]},
        {"examples/echo-bot.md", [title: "Echo Bot Example"]}
      ],
      groups_for_extras: [
        {"Overview", ["README.md", "CHANGELOG.md", "user_docs/glossary.md"]},
        {"Getting Started", ~r/user_docs\/getting-started\//},
        {"Guides", ~r/user_docs\/guides\//},
        {"Reference", ~r/user_docs\/reference\//},
        {"Troubleshooting", ~r/user_docs\/troubleshooting\//},
        {"Examples", ~r/examples\//}
      ]
    ]
  end

  defp description do
    """
    WhatsApp Web API client for Elixir. Full-featured port of Baileys with \
    end-to-end Signal Protocol encryption, multi-device support, groups, communities, \
    media, newsletters, and native BEAM fault tolerance.\
    """
  end

  defp package do
    [
      maintainers: ["Jeff Huen"],
      licenses: ["MIT"],
      files: package_files(),
      links: %{
        "GitHub" => "https://github.com/jeffhuen/baileys_ex",
        "Changelog" => "https://github.com/jeffhuen/baileys_ex/blob/main/CHANGELOG.md",
        "Baileys (upstream reference)" => "https://github.com/WhiskeySockets/Baileys"
      }
    ]
  end

  defp package_files do
    [
      ".formatter.exs",
      "CHANGELOG.md",
      "LICENSE",
      "README.md",
      "examples/echo_bot.exs",
      "examples/echo-bot.md",
      "mix.exs",
      "native/baileys_nif/.cargo/config.toml",
      "native/baileys_nif/Cargo.lock",
      "native/baileys_nif/Cargo.toml",
      "user_docs/glossary.md"
    ] ++
      Path.wildcard("lib/**/*.ex") ++
      Path.wildcard("native/baileys_nif/src/**/*.rs") ++
      Path.wildcard("priv/proto/**/*") ++
      Path.wildcard("priv/wam/**/*") ++
      Path.wildcard("user_docs/getting-started/**/*.md") ++
      Path.wildcard("user_docs/guides/**/*.md") ++
      Path.wildcard("user_docs/reference/**/*.md") ++
      Path.wildcard("user_docs/troubleshooting/**/*.md")
  end
end
