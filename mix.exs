defmodule BaileysEx.MixProject do
  use Mix.Project

  def project do
    [
      app: :baileys_ex,
      version: "0.1.0",
      description: description(),
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
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
      extras: [
        "README.md",
        "guides/getting-started.md",
        "guides/authentication.md",
        "guides/sending-messages.md",
        "guides/receiving-messages.md",
        "guides/media.md",
        "guides/groups.md",
        "guides/custom-persistence.md",
        "user_docs/glossary.md",
        "user_docs/guides/manage-app-state-sync.md",
        "user_docs/troubleshooting/app-state-sync-issues.md"
      ],
      groups_for_extras: [
        Overview: ["README.md", "user_docs/glossary.md"],
        Guides: [
          "guides/getting-started.md",
          "guides/authentication.md",
          "guides/sending-messages.md",
          "guides/receiving-messages.md",
          "guides/media.md",
          "guides/groups.md",
          "guides/custom-persistence.md",
          "user_docs/guides/manage-app-state-sync.md"
        ],
        Troubleshooting: ~r/user_docs\/troubleshooting\//
      ]
    ]
  end

  defp description do
    "Behavior-accurate Elixir port of Baileys 7.00rc9 for WhatsApp Web automation"
  end

  defp package do
    [
      licenses: ["MIT"],
      files: [
        ".formatter.exs",
        "LICENSE",
        "README.md",
        "examples",
        "guides",
        "lib",
        "mix.exs",
        "native/baileys_nif/.cargo",
        "native/baileys_nif/Cargo.lock",
        "native/baileys_nif/Cargo.toml",
        "native/baileys_nif/src",
        "priv/proto",
        "priv/wam",
        "user_docs"
      ],
      links: %{
        "GitHub" => "https://github.com/jeffhuen/baileys_ex",
        "Baileys Reference" => "https://github.com/WhiskeySockets/Baileys"
      }
    ]
  end
end
