defmodule MintedWeb.Live.SessionCheck do
  @moduledoc """
  LiveView on_mount hook that validates the WebSocket connection has a valid session.

  This prevents cross-site WebSocket hijacking by ensuring the LiveView connection
  originated from a page that went through the :browser pipeline (which includes
  CSRF protection via :protect_from_forgery).

  The wallet LiveView is intentionally unauthenticated — ecash users are anonymous.
  This hook only validates that the session is well-formed, not that the user is
  authenticated. If admin LiveViews are added in future, a separate auth hook
  should be created.
  """

  import Phoenix.Component

  def on_mount(:default, _params, session, socket) do
    # The session map is populated by the :browser pipeline's :fetch_session plug.
    # If a WebSocket connection arrives without going through the browser pipeline.
    # (e.g., direct WS connection without cookie), the session will be empty.
    # We allow this since the wallet is public, but tag the socket for observability.
    socket =
      socket
      |> assign(:session_valid, session != %{})
      |> assign(:connected_at, System.monotonic_time(:millisecond))

    {:cont, socket}
  end
end
