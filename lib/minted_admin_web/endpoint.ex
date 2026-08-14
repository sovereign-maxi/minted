defmodule MintedAdminWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :minted

  # .onion services use plain HTTP scheme despite having end-to-end encryption.
  # secure: true would prevent the cookie from being sent over http://*.onion.
  @session_options [
    store: :cookie,
    key: "_minted_admin_key",
    signing_salt: "minted_admin_s",
    same_site: "Strict",
    secure: Application.compile_env(:minted, :cookie_secure, false)
  ]

  socket "/live", Phoenix.LiveView.Socket,
    websocket: [
      connect_info: [session: @session_options],
      max_frame_size: 16_384,
      compress: true,
      timeout: 120_000
    ]

  # OnionOnly runs first so static asset paths can't be served to a
  # request whose Host header is not the configured admin .onion.
  # Plug.Static short-circuits on match; placing it before the gate
  # would let a misconfigured listener leak digested-asset hashes
  # and confirm the admin endpoint exists at a given host/port.
  plug MintedAdminWeb.Plugs.OnionOnly

  plug Plug.Static,
    at: "/",
    from: :minted,
    gzip: true,
    only: MintedWeb.static_paths(),
    cache_control_for_etags: "public, max-age=31536000, immutable"

  # Blueprint design system assets (CSS + fonts). `gzip: true` requires
  # `.gz` siblings in the dep's own priv/static (phx.digest only touches
  # the app's priv/static, not deps).
  plug Plug.Static,
    at: "/",
    from: {:blueprint, "priv/static"},
    gzip: true,
    only: ~w(assets fonts)

  plug Plug.Parsers,
    parsers: [:urlencoded, :json],
    pass: ["text/plain"],
    json_decoder: Phoenix.json_library(),
    length: 1_000_000

  plug Plug.Session, @session_options
  plug MintedWeb.Plugs.SecurityHeaders
  plug MintedAdminWeb.Router
end
