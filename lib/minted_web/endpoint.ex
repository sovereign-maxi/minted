defmodule MintedWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :minted

  # Tor-only: connections arrive on HTTP loopback from the Tor daemon.
  # `secure: false` because .onion serves HTTP end-to-end (Tor provides
  # the transport encryption at the network layer, not TLS at the
  # cookie layer).
  @session_options [
    store: :cookie,
    key: "_minted_key",
    signing_salt: "minted_s",
    same_site: "Strict",
    secure: false
  ]

  socket "/live", Phoenix.LiveView.Socket,
    websocket: [
      connect_info: [session: @session_options],
      max_frame_size: 131_072,
      compress: true,
      timeout: 120_000
    ]

  plug Plug.Static,
    at: "/",
    from: :minted,
    gzip: true,
    only: MintedWeb.static_paths(),
    cache_control_for_etags: "public, max-age=31536000, immutable"

  # Serve Blueprint design system assets (CSS + fonts) from the blueprint dependency.
  # `gzip: true` requires `.gz` siblings in the dep's own priv/static (phx.digest
  # only touches the app's priv/static, not deps).
  plug Plug.Static,
    at: "/",
    from: {:blueprint, "priv/static"},
    gzip: true,
    only: ~w(assets fonts)

  plug MintedWeb.Plugs.ConditionalBodyParser

  plug Plug.Session, @session_options
  plug MintedWeb.Plugs.SecurityHeaders
  plug MintedWeb.Router
end
