import Config

# Production compile-time configuration
# Runtime configuration is in runtime.exs

config :minted, MintedWeb.Endpoint,
  server: true,
  cache_static_manifest: "priv/static/cache_manifest.json"

config :minted, MintedAdminWeb.Endpoint,
  server: true,
  cache_static_manifest: "priv/static/cache_manifest.json"

# PoW difficulty must match runtime value (compile-time validated)
config :minted, :identity, pow_min_difficulty: 20

# Do not print debug messages in production
config :logger, level: :info

# JSON logging for production structured logs
config :logger, :default_formatter, format: "$time $metadata[$level] $message\n"
