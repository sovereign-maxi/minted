import Config

# Test-specific configuration

config :minted, :lightning,
  phoenixd_url: "http://127.0.0.1:9740",
  phoenixd_password: "test-password",
  fee_ppm: 7_500,
  deposit_fee_ppm: 7_500,
  withdrawal_fee_ppm: 0,
  routing_fee_estimate_ppm: 5_000,
  routing_fee_min_sats: 2,
  fee_min_sats: 1,
  liquidity_high_watermark: 100_000,
  liquidity_low_watermark: 50_000,
  liquidity_low_sats: 100_000,
  liquidity_critical_sats: 10_000

config :minted, :phoenixd_module, Minted.Lightning.PhoenixdMock

# Skip starting Lightning children in test — tests start them individually
config :minted, :skip_lightning_children, true

# Fixed webhook secret so plug wrappers that read runtime config have
# a value to compare signatures against. Production reads WEBHOOK_SECRET
# from the environment; see config/runtime.exs.
config :minted, :webhook_secret, "test-webhook-secret-32-bytes-min-padding-xxxxx"

config :minted, :identity,
  # Minimal PoW difficulty for tests
  pow_min_difficulty: 4,
  pow_max_difficulty: 8,
  # Faster rate limit windows for tests
  rate_limit_window_ms: 1_000,
  # Disable request gate for tests
  request_gate_enabled: false

config :minted, :reserves,
  # Shorter intervals for tests
  proof_interval_ms: 1_000,
  attestation_window_ms: 500,
  # Local signer — no consensus required in test
  signer: :default

config :minted, :telemetry,
  poll_interval_ms: 100,
  alert_interval_ms: 500,
  stream_batch_ms: 50,
  # Auto-halt is driven explicitly by the tests that exercise it —
  # leaving it on would let an organic alert (disk, liability) halt
  # the node mid-suite and break unrelated tests.
  auto_halt_enabled: false

# Storage - use OS temp directories for tests.
# Avoids stale-state races when CubDB's data_dir is cleaned while the app is running.
test_tmp = Path.join(System.tmp_dir!(), "minted_test")
File.rm_rf!(test_tmp)
File.mkdir_p!(test_tmp)

config :minted, data_dir: test_tmp

# Tor — bypass mode for tests
config :minted, :tor,
  acl_mode: :bypass,
  onion_location_enabled: false

# Web endpoint — use random port for tests
config :minted, MintedWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 0],
  server: false,
  check_origin: false,
  secret_key_base: String.duplicate("a", 64),
  live_view: [signing_salt: "test-signing-salt-for-liveview-tests"]

# Admin endpoint — use random port for tests
config :minted, MintedAdminWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 0],
  server: false,
  check_origin: false,
  secret_key_base: String.duplicate("b", 64),
  live_view: [signing_salt: "test-signing-salt-for-admin-tests"]

config :minted, :clock, Minted.ClockMock

config :minted, :env, :test

# Test fixtures intentionally include corrupt-WAL inputs to exercise
# the recovery skip path; production halts.
config :minted, :wal, halt_on_corrupt: false

config :logger, level: :warning
