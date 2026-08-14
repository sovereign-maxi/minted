defmodule MintedWeb.Router do
  use MintedWeb, :router

  pipeline :api do
    plug :accepts, ["json"]
    plug Minted.Identity.Gate
  end

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {MintedWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :health do
    plug :accepts, ["json"]
  end

  scope "/health", MintedWeb do
    pipe_through :health
    get "/", HealthController, :ready
    get "/live", HealthController, :live
    get "/ready", HealthController, :ready
  end

  scope "/", MintedWeb do
    pipe_through :browser

    # Wallet LiveView is intentionally unauthenticated — ecash users are anonymous.
    # The :browser pipeline includes :protect_from_forgery (CSRF) and :put_secure_browser_headers.
    # If admin LiveViews are added in future, they MUST use a separate live_session
    # with on_mount auth hooks (e.g., MintedWeb.Live.AdminAuthHook).
    get "/", RedirectController, :to_wallet

    live_session :wallet, on_mount: [{MintedWeb.Live.SessionCheck, :default}] do
      live "/wallet", WalletLive, :index
    end

    # Server-side welcome-modal dismissal — JS-free HTML form POST so
    # Tor Browser safest-mode users can still get past the phishing
    # defense screen.
    post "/welcome/dismiss", WelcomeController, :dismiss
  end

  # Internal webhook endpoint for co-located Phoenixd. HMAC-verified
  # via shared secret; the endpoint's Plug.Parsers is skipped for
  # `/internal/webhooks/*` so the raw body remains available for
  # signature verification.
  scope "/internal" do
    forward "/webhooks/phoenixd", MintedWeb.Plugs.PhoenixdWebhook
  end

  scope "/v1", MintedWeb do
    pipe_through :api

    # Mint (deposit) — NUT-04.
    post "/mint/quote", MintController, :create_quote
    post "/mint/quote/:id", MintController, :claim_quote

    # Melt (withdrawal) — NUT-05.
    post "/melt/quote", MintController, :melt_quote
    post "/melt/quote/:id", MintController, :melt

    # Swap — NUT-03.
    post "/swap", MintController, :swap

    # Spend check — NUT-07.
    post "/check", MintController, :check

    # Info — NUT-06.
    get "/info", InfoController, :info

    # Keysets — NUT-01/02.
    get "/keysets", InfoController, :keysets
    get "/keysets/:id", InfoController, :keyset

    # Reserves.
    get "/reserves", ReservesController, :show
    get "/reserves/history", ReservesController, :history
  end
end
