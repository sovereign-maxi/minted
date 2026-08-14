defmodule MintedWeb.WelcomeController do
  @moduledoc """
  Handles dismissal of the first-visit welcome modal.

  The modal is a phishing-defense + orientation surface rendered by
  the root layout when `get_session(conn, "welcomed")` is not true.
  Users click CONTINUE, which submits an HTML form here; we mark
  the session welcomed and redirect back to where they were.

  Deliberately server-side and JavaScript-free — Tor Browser
  safest-mode disables JS, and the welcome surface is exactly the
  interaction we cannot afford to break for that audience.

  Mirrors the pattern used by `PerpWalkWeb.WelcomeController` in the
  sibling product — same phishing-clone threat, same JS-free
  constraint.
  """

  use MintedWeb, :controller

  @doc """
  Safely determines whether this connection's session is marked
  welcomed. Returns `true` (skip modal) if the session hasn't been
  fetched — some render paths don't have session state attached,
  and defaulting to "welcomed" avoids spurious modal renders in
  those contexts.
  """
  @spec welcomed?(Plug.Conn.t()) :: boolean()
  def welcomed?(%Plug.Conn{private: %{plug_session: session}}) when is_map(session),
    do: Map.get(session, "welcomed") == true

  def welcomed?(_conn), do: true

  @doc """
  Marks the session as having seen the welcome modal, then
  redirects to the safe caller-supplied path (or `/wallet` as
  fallback).
  """
  def dismiss(conn, params) do
    conn
    |> put_session(:welcomed, true)
    |> redirect(to: safe_redirect(params["redirect_to"]))
  end

  # Only accept same-origin relative paths — reject external URLs,
  # protocol-relative URLs, and anything that would bounce the user
  # off the mint.
  #
  # Backslashes are rejected because Chrome, Firefox, and Safari all
  # normalize `\` to `/` during URL parsing: `/\evil.com` posts to
  # the welcome route as an ordinary-looking path but the browser
  # follows it to `//evil.com` (protocol-relative external redirect).
  # The welcome surface is the anti-phishing gate — an open redirect
  # here is exactly the phishing bounce it exists to prevent.
  defp safe_redirect(nil), do: "/wallet"
  defp safe_redirect(""), do: "/wallet"

  defp safe_redirect(<<"/", rest::binary>>) do
    cond do
      String.starts_with?(rest, "/") -> "/wallet"
      String.contains?(rest, "\\") -> "/wallet"
      true -> "/" <> rest
    end
  end

  defp safe_redirect(_), do: "/wallet"
end
