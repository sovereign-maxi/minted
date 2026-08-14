defmodule Minted.MixProject do
  use Mix.Project

  @version "0.1.0"

  def project do
    [
      app: :minted,
      version: @version,
      elixir: "~> 1.19",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      releases: [
        minted: [
          include_executables_for: [:unix],
          applications: [runtime_tools: :permanent],
          validate_compile_env: true
        ]
      ],
      name: "Minted",
      description: "Bitcoin Without a Trail",
      dialyzer: [plt_add_apps: [:mix, :ex_unit]]
    ]
  end

  def application do
    [
      extra_applications: [:logger, :runtime_tools, :inets, :ssl],
      mod: {Minted.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      # Web — pinned to resolved major/minor for launch freeze; revisit post-launch.
      {:phoenix, "~> 1.8"},
      {:phoenix_html, "~> 4.2"},
      {:phoenix_live_view, "~> 1.1"},
      {:phoenix_live_reload, "~> 1.5", only: :dev},
      {:plug_cowboy, "~> 2.8"},
      {:jason, "~> 1.4"},
      {:decimal, "~> 3.0"},

      # HTTP client (Phoenixd API, Nostr relay publishing)
      {:finch, "~> 0.21"},

      # WebSocket client for Nostr relays (NIP-01 event submission)
      {:mint_web_socket, "~> 1.0"},

      # Oracle (shared price feed primitives)
      {:oracle, path: "../oracle"},

      # Lightning (Client, InvoiceManager, PaymentExecutor, LiquidityMonitor)
      {:fire_bird, path: "../firebird"},

      # Cashu crypto primitives (secp256k1 NIF)
      {:cashew, path: "../cashew"},

      # Common design system (CSS + LiveView components)
      {:blueprint, path: "../blueprint"},

      # Shared precision arithmetic and conversion constants
      {:core, path: "../core"},

      # Anti-sybil: PoW challenges, rate limiting, circuit extraction
      {:seer, path: "../seer"},

      # Storage primitives: WAL, atomic counters, pluggable backends
      {:locker, path: "../locker"},

      # Reserve proof generation, attestation, deficit detection
      {:vault, path: "../vault"},

      # Persistent key-value store (spent set cold tier)
      {:cubdb, "~> 2.0"},

      # Structured logging (prod)
      {:logger_json, "~> 6.2"},

      # Telemetry
      {:telemetry, "~> 1.3"},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.1"},

      # Asset bundling (standalone binary, no node.js required)
      {:esbuild, "~> 0.8", runtime: Mix.env() == :dev},

      # Dev & Test
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:mix_audit, "~> 2.1", only: [:dev, :test], runtime: false},
      {:stream_data, "~> 1.1", only: :test},
      {:mox, "~> 1.2", only: :test},
      {:lazy_html, "~> 0.1", only: :test}
    ]
  end

  defp aliases do
    [
      setup: ["deps.get", "esbuild.install --if-missing"],
      test: ["test"],
      "assets.deploy": [
        "esbuild minted --minify",
        "phx.digest"
      ]
    ]
  end
end
