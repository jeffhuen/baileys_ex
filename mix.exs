defmodule BaileysEx.MixProject do
  use Mix.Project

  def project do
    [
      app: :baileys_ex,
      version: "0.1.0",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
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
        "user_docs/glossary.md",
        "user_docs/guides/manage-app-state-sync.md",
        "user_docs/troubleshooting/app-state-sync-issues.md"
      ],
      groups_for_extras: [
        Overview: ["README.md", "user_docs/glossary.md"],
        Guides: ~r/user_docs\/guides\//,
        Troubleshooting: ~r/user_docs\/troubleshooting\//
      ]
    ]
  end
end
