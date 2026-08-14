defmodule MintedAdminWeb.Router do
  @moduledoc """
  Admin web router — serves the read-only dashboard LiveView.

  The admin endpoint is bound to its own Tor hidden service (.onion). The
  .onion address itself is the capability — no password or token auth.
  All destructive operations happen via remote iex (`iex --remsh`), not
  HTTP, so no write endpoints are exposed here.
  """

  use MintedWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {MintedAdminWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  scope "/admin", MintedAdminWeb do
    pipe_through :browser

    live_session :admin do
      live "/dashboard", Live.Dashboard, :index
    end
  end
end
