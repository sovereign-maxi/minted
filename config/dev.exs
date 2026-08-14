import Config

# Development-specific configuration

# Session signing salt — dev only. In prod this is derived from SECRET_KEY_BASE at runtime.
config :minted, :lightning,
  phoenixd_url: "http://127.0.0.1:9740",
  phoenixd_password: "dev-password"

config :minted, :identity,
  # Lower PoW difficulty for dev
  pow_min_difficulty: 8,
  pow_max_difficulty: 16

config :minted, MintedWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4000],
  secret_key_base: "dev-only-not-for-production-minted-secret-key-base-that-is-at-least-64-bytes-long-ok",
  server: true,
  code_reloader: false,
  check_origin: false,
  watchers: [
    esbuild: {Esbuild, :install_and_run, [:minted, ~w(--sourcemap=inline --watch)]}
  ]

config :minted, MintedAdminWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4001],
  secret_key_base: "dev-only-not-for-production-minted-admin-secret-key-base-that-is-at-least-64-bytes",
  server: true,
  check_origin: false

config :minted, :env, :dev

# Dev runs against on-disk WAL that may carry corrupt entries from
# prior experiments; production halts.
config :minted, :wal, halt_on_corrupt: false

config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id, :module]
