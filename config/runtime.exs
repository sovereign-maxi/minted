import Config

if config_env() == :prod do
  # Structured JSON logging for production (human-readable stays in dev/test).
  # Metadata is an explicit allowlist — never :all — so ad-hoc Logger.info/2
  # metadata keys introduced in the future cannot silently leak sensitive
  # values into the log stream. Only structural keys (location info) and
  # crash_reason (required for crash triage) are permitted.
  config :logger, :default_handler,
    formatter:
      {LoggerJSON.Formatters.Basic,
       metadata: [
         :application,
         :module,
         :function,
         :file,
         :line,
         :mfa,
         :pid,
         :request_id,
         :crash_reason
       ]}

  config :logger, level: :info

  # Web endpoint — bind to localhost, Tor proxies to this
  port = String.to_integer(System.get_env("PORT") || "4000")

  # Admin endpoint — bind to localhost:4001
  admin_port = String.to_integer(System.get_env("ADMIN_PORT") || "4001")

  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise "SECRET_KEY_BASE environment variable is required in production"

  # check_origin pinned to the configured hostnames. Phoenix's :conn
  # shorthand only compares the WebSocket Origin against the
  # request's own Host header — a forged Host on the loopback
  # listener defeats it. Explicit allow-list is true cross-origin
  # protection.
  user_onion =
    System.get_env("TOR_ONION_HOSTNAME") ||
      raise "TOR_ONION_HOSTNAME environment variable is required in production"

  admin_onion = System.get_env("TOR_ADMIN_ONION_HOSTNAME") || user_onion

  admin_check_origin = ["http://#{admin_onion}"]

  config :minted, MintedWeb.Endpoint,
    http: [ip: {127, 0, 0, 1}, port: port, compress: true],
    secret_key_base: secret_key_base,
    check_origin: ["http://#{user_onion}"],
    server: true

  config :minted, MintedAdminWeb.Endpoint,
    http: [ip: {127, 0, 0, 1}, port: admin_port, compress: true],
    secret_key_base: secret_key_base,
    check_origin: admin_check_origin,
    server: true

  # Lightning / Phoenixd. Phoenixd auto-generates ~32-byte httpPassword
  # by default; the floor catches operator-typed weak values.
  phoenixd_password =
    System.get_env("PHOENIXD_PASSWORD") ||
      raise("PHOENIXD_PASSWORD environment variable is required")

  if byte_size(phoenixd_password) < 16 do
    raise "PHOENIXD_PASSWORD must be at least 16 bytes (got #{byte_size(phoenixd_password)})"
  end

  config :minted, :lightning,
    phoenixd_url: System.get_env("PHOENIXD_URL") || "http://127.0.0.1:9740",
    phoenixd_password: phoenixd_password

  # Webhook HMAC secret for authenticating Phoenixd callbacks. Must be at
  # least 32 bytes so HMAC-SHA256 runs at full strength; Erlang's :crypto
  # happily accepts shorter keys but a typo'd "test" or "changeme" would
  # silently degrade the forgery-resistance of every webhook we accept.
  webhook_secret =
    System.get_env("WEBHOOK_SECRET") ||
      raise(
        "WEBHOOK_SECRET environment variable is required in production. " <>
          "Phoenixd webhook callbacks cannot be authenticated without it."
      )

  if byte_size(webhook_secret) < 32 do
    raise "WEBHOOK_SECRET must be at least 32 bytes (got #{byte_size(webhook_secret)}). " <>
            "Generate with: openssl rand -hex 32"
  end

  config :minted, :webhook_secret, webhook_secret

  # Tor
  config :minted, :tor,
    mesh_port: String.to_integer(System.get_env("MESH_PORT") || "8443"),
    control_port: String.to_integer(System.get_env("TOR_CONTROL_PORT") || "9051"),
    control_password: System.get_env("TOR_CONTROL_PASSWORD"),
    cookie_path: System.get_env("TOR_COOKIE_PATH") || "/run/tor/control.authcookie",
    socks_port: String.to_integer(System.get_env("TOR_SOCKS_PORT") || "9050"),
    hidden_service_base_dir: System.get_env("TOR_HIDDEN_SERVICE_DIR") || "/var/lib/tor/minted",
    acl_mode: :enforce,
    onion_location_enabled: true

  # Tor control protocol — configuration for Tor app instance.
  config :minted, :tor_control,
    host: "127.0.0.1",
    port: String.to_integer(System.get_env("TOR_APP_CONTROL_PORT") || "9151"),
    cookie_path: System.get_env("TOR_COOKIE_PATH") || "/run/tor-instances/app/control.authcookie"

  # Tor HTTP CONNECT tunnel — required in prod so ALL outbound HTTP
  # (Phoenixd webhooks on loopback are exempt; price feeds, Nostr relay
  # publishing go through this) never leaks the mint's server IP. Must be
  # configured on the Tor side via HTTPTunnelPort in torrc.
  tor_tunnel_host = System.get_env("TOR_HTTP_TUNNEL_HOST") || "127.0.0.1"

  tor_tunnel_port =
    System.get_env("TOR_HTTP_TUNNEL_PORT") ||
      raise(
        "TOR_HTTP_TUNNEL_PORT environment variable is required in production. " <>
          "Finch will refuse to start without it — shipping without Tor egress " <>
          "would deanonymize the mint server on every reserve proof and price poll."
      )

  config :minted,
         :tor_http_tunnel,
         {tor_tunnel_host, String.to_integer(tor_tunnel_port)}

  # Pre-cache Tor onion hostnames from env (avoids filesystem permission issues).
  # Admin uses a separate .onion address; falls back to the user address if not set.
  # Both must be present in prod — the OnionOnly plug uses these as the auth
  # boundary on the admin endpoint, and an unset value would fall through to the
  # "no admin hostname configured" branch.
  onion_hostname =
    System.get_env("TOR_ONION_HOSTNAME") ||
      raise "TOR_ONION_HOSTNAME environment variable is required in production"

  admin_onion_hostname =
    System.get_env("TOR_ADMIN_ONION_HOSTNAME") ||
      raise "TOR_ADMIN_ONION_HOSTNAME environment variable is required in production"

  config :minted, :tor_hostnames, %{
    user: onion_hostname,
    admin: admin_onion_hostname,
    node: onion_hostname
  }

  # PoW difficulty: 20 bits in prod (~100ms solve time) for meaningful DoS protection (#35).
  # Dev/test uses 12 bits from config.exs for fast iteration.
  pow_difficulty =
    case Integer.parse(System.get_env("POW_DIFFICULTY") || "20") do
      {v, ""} when v >= 12 and v <= 28 -> v
      _ -> 20
    end

  config :minted, :identity, pow_min_difficulty: pow_difficulty

  # House-income withdrawal minimum, in sats. Filters accidental
  # micro-requests. Deployment-tunable — smaller floors let the
  # operator exercise the withdrawal path on a low-volume mint;
  # production default is 1000.
  house_min_withdrawal_sats =
    case Integer.parse(System.get_env("HOUSE_MIN_WITHDRAWAL_SATS") || "1000") do
      {v, ""} when v >= 1 -> v
      _ -> 1000
    end

  config :minted, :house_income_min_withdrawal_sats, house_min_withdrawal_sats

  # Persistent data directory — must survive across deployments.
  # Defaults to /home/minted/data (absolute path outside release tree).
  data_dir = System.get_env("MINTED_DATA_DIR") || "/home/minted/data"

  config :minted, data_dir: data_dir

  # Disk mounts to monitor on the dashboard (env: comma-separated paths).
  disk_mounts =
    case System.get_env("DISK_MOUNTS") do
      nil -> ["/"]
      paths -> paths |> String.split(",", trim: true) |> Enum.map(&String.trim/1)
    end

  config :minted, disk_mounts: disk_mounts

  config :minted, :env, :prod

  # Per-host label surfaced in Nostr alert prefixes so a single
  # operator client can distinguish prod (N1) from staging (S1) at
  # a glance. Ansible derives the value from the inventory hostname
  # suffix; unset falls back to plain `[MINTED]` prefix.
  if node_label = System.get_env("NODE_LABEL") do
    config :minted, :node_label, node_label
  end

  # Reserves — Nostr relay list (NostrPublisher reads from :nostr_relays key)
  if relays = System.get_env("NOSTR_RELAYS") do
    config :minted, :nostr_relays, String.split(relays, ",", trim: true)
  end

  # Operator alert delivery over Nostr (NIP-04 encrypted DMs).
  # Requires NOSTR_OPERATOR_PUBKEY (64-char hex x-only) and NOSTR_ALERT_RELAYS.
  # Alerts are only published when both are set.
  #
  # HEARTBEAT_ENABLED (default true) + HEARTBEAT_INTERVAL_HOURS (default 24)
  # control the periodic proof-of-life DM. Absence of the expected heartbeat
  # is a signal something is wrong, so keep it enabled unless you have a
  # specific reason to disable.
  heartbeat_enabled =
    case System.get_env("HEARTBEAT_ENABLED") do
      "false" -> false
      "0" -> false
      _ -> true
    end

  heartbeat_interval_hours =
    case Integer.parse(System.get_env("HEARTBEAT_INTERVAL_HOURS") || "24") do
      {h, ""} when h > 0 and h <= 168 -> h
      _ -> 24
    end

  nostr_alert_cfg =
    [
      operator_pubkey: System.get_env("NOSTR_OPERATOR_PUBKEY"),
      relays:
        case System.get_env("NOSTR_ALERT_RELAYS") || System.get_env("NOSTR_RELAYS") do
          nil -> []
          s -> String.split(s, ",", trim: true)
        end,
      heartbeat: [
        enabled: heartbeat_enabled,
        interval_ms: heartbeat_interval_hours * 60 * 60 * 1000
      ]
    ]
    |> Enum.reject(fn {_, v} -> is_nil(v) end)

  if nostr_alert_cfg != [] do
    config :minted, :nostr, nostr_alert_cfg
  end

  # MINTED_ENCRYPTION_KEY: master AES-256 key for every at-rest secret
  # the application persists (keyset private keys, Reserves Nostr
  # signing key, Vault.Generator guardian key).
  enc_key_b64 =
    System.get_env("MINTED_ENCRYPTION_KEY") ||
      raise "MINTED_ENCRYPTION_KEY environment variable is required in production. " <>
              "Generate with: openssl rand -base64 32"

  enc_key =
    case Base.decode64(enc_key_b64) do
      {:ok, decoded} -> decoded
      :error -> raise "MINTED_ENCRYPTION_KEY must be valid base64"
    end

  if byte_size(enc_key) != 32 do
    raise "MINTED_ENCRYPTION_KEY must decode to exactly 32 bytes (AES-256), " <>
            "got #{byte_size(enc_key)} bytes"
  end

  config :minted, :encryption_key, enc_key
end
