import Config

# Shared compile-time configuration

# Mint context
config :minted, :mint,
  # Power-of-2 denomination range: 2^0 through 2^20 sats
  denomination_exponents: 0..20

# Lightning context
config :minted, :lightning,
  # Phoenixd REST API base URL
  phoenixd_url: "http://127.0.0.1:9740",
  # Deposit fee: 0.75% = 7500 ppm. Entire operator margin collected at deposit.
  fee_ppm: 7_500,
  deposit_fee_ppm: 7_500,
  # Withdrawal: no percentage fee. Routing fee is estimated and passed through to user.
  withdrawal_fee_ppm: 0,
  # Routing fee estimate for withdrawals (ppm of payment amount, floor of 2 sats).
  # Actual routing fee is deducted from change after payment.
  routing_fee_estimate_ppm: 5_000,
  routing_fee_min_sats: 2,
  # Minimum fee in sats
  fee_min_sats: 1,
  # Liquidity monitoring thresholds in sats
  liquidity_high_watermark: 100_000,
  liquidity_low_watermark: 50_000,
  liquidity_low_sats: 100_000,
  liquidity_critical_sats: 10_000,
  phoenixd_timeout_ms: 30_000

# Reserves context
config :minted, :reserves,
  # Proof generation interval in ms (10 min)
  proof_interval_ms: 600_000,
  # Attestation collection window in ms
  attestation_window_ms: 60_000,
  # Reserve ratio thresholds
  healthy_ratio: 1.01,
  warning_ratio: 1.00,
  critical_ratio: 0.95

# Identity context
config :minted, :identity,
  # Rate limit: requests per window
  rate_limit_requests: 20,
  # Rate limit window in ms
  rate_limit_window_ms: 60_000,
  # PoW difficulty range (bits)
  pow_min_difficulty: 12,
  pow_max_difficulty: 28

# Telemetry context
config :minted, :telemetry,
  # Metric poll interval in ms
  poll_interval_ms: 10_000,
  # Alert evaluation interval in ms
  alert_interval_ms: 15_000,
  # Event stream batch interval in ms
  stream_batch_ms: 100

# Storage context
config :minted,
  data_dir: "data",
  backup_overdue_ms: 7_200_000,
  spent_set_backend: Minted.Storage.Backends.CubDB

# Oracle context
config :oracle, :http_client, Minted.Oracle.Client

config :minted, :price_feed,
  enabled: true,
  poll_interval_ms: 60_000,
  sources: [:coinbase, :binance, :kraken]

# Tor context
config :minted, :tor,
  acl_mode: :bypass,
  onion_location_enabled: false

# esbuild — JS bundling (standalone binary, no node.js)
config :esbuild,
  version: "0.21.5",
  minted: [
    args: ~w(js/app.js --bundle --outdir=../priv/static/assets --external:/fonts/* --external:/images/*),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => Path.expand("../deps", __DIR__)}
  ]

# Web endpoint — user API + wallet LiveView
config :minted, MintedWeb.Endpoint,
  url: [host: "localhost"],
  http: [ip: {127, 0, 0, 1}, port: 4000],
  render_errors: [
    formats: [html: MintedWeb.ErrorHTML, json: MintedWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Minted.PubSub,
  live_view: [signing_salt: "minted_lv"],
  server: false,
  drainer: [shutdown: 30_000]

# Admin endpoint — read-only dashboard LiveView (no auth; .onion-gated)
config :minted, MintedAdminWeb.Endpoint,
  url: [host: "localhost"],
  http: [ip: {127, 0, 0, 1}, port: 4001],
  render_errors: [
    formats: [html: MintedWeb.ErrorHTML, json: MintedWeb.ErrorJSON],
    layout: false
  ],
  secret_key_base: :crypto.strong_rand_bytes(64) |> Base.encode64(padding: false) |> binary_part(0, 64),
  pubsub_server: Minted.PubSub,
  live_view: [signing_salt: "minted_admin_lv"],
  server: false,
  drainer: [shutdown: 10_000]

# Logger metadata filter — redact sensitive fields before they reach formatters
config :logger, :default_handler,
  filters: [
    safe_metadata: {&Minted.Telemetry.Filter.filter/2, []}
  ]

# JSON library
config :phoenix, :json_library, Jason

# Extend phx.digest's gzip pass to include `.wasm` — Nutty WASM (BDHKE
# operations in the Cashu wallet) is 42KB uncompressed and compresses
# well; without this the file ships raw over Tor. Phoenix's default list
# `~w(.js .map .css .txt .text .html .json .svg .eot .ttf)` predates
# WebAssembly-served static assets.
config :phoenix,
       :gzippable_exts,
       ~w(.js .map .css .txt .text .html .json .svg .eot .ttf .wasm)

# Phoenix's default request logger emits Parameters: %{...} on
# every controller dispatch with ["password"] as the only filter.
# Cashu NUT request bodies carry token secrets, blinded messages,
# and signatures — anything in the params map is enough to
# correlate spends across mint/melt/swap. Drop the params line
# entirely; structured prod logs go through Telemetry.Filter and
# the LoggerJSON formatter instead.
config :phoenix, :filter_parameters, {:keep, []}

import_config "#{config_env()}.exs"
