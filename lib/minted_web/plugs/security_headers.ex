defmodule MintedWeb.Plugs.SecurityHeaders do
  @moduledoc """
  Plug enforcing strict security headers and stripping identifying headers.

  Ensures no response leaks information about the server software,
  framework, or infrastructure. All responses get strict CSP,
  cache-control, and standard security headers.

  For LiveView routes, the CSP allows 'self' scripts, styles, connects,
  and inline styles needed for LiveView DOM patching.
  """

  # CORS is intentionally not configured. The API is accessed via Tor hidden
  # services or direct HTTP by non-browser Cashu wallets. The CSP
  # `default-src 'none'` on API routes provides implicit cross-origin protection
  # for the rare case of browser-based access. If browser wallet support is
  # added in the future, CORS headers should be explicitly configured here.

  @behaviour Plug

  import Plug.Conn

  @api_csp "default-src 'none'; frame-ancestors 'none'"

  @browser_csp [
                 "default-src 'self'",
                 # wasm-unsafe-eval required for Nutty WASM BDHKE operations in the
                 # wallet LiveView. Cannot be removed without breaking client-side crypto.
                 "script-src 'self' 'wasm-unsafe-eval'",
                 # LiveView DOM patching requires inline styles.
                 "style-src 'self' 'unsafe-inline'",
                 "font-src 'self'",
                 "img-src 'self' data:",
                 "media-src 'self' data:",
                 "connect-src 'self'",
                 "frame-ancestors 'none'"
               ]
               |> Enum.join("; ")

  @common_headers [
    {"x-content-type-options", "nosniff"},
    {"x-frame-options", "DENY"},
    {"cache-control", "no-store"},
    {"referrer-policy", "no-referrer"}
  ]

  # HSTS is meaningless on `.onion` (no DNS to upgrade, no MITM
  # surface) and slightly leaky if a user ever visits the clearnet
  # mirror from the same browser. Emit only when the request is
  # actually HTTPS.
  @hsts_header {"strict-transport-security", "max-age=63072000; includeSubDomains"}

  @stripped_headers ["server", "x-powered-by", "x-request-id"]

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    csp = if browser_request?(conn), do: @browser_csp, else: @api_csp

    conn
    |> put_resp_header("content-security-policy", csp)
    |> set_common_headers()
    |> maybe_set_hsts()
    |> register_before_send(&strip_identifying_headers/1)
  end

  defp maybe_set_hsts(%Plug.Conn{scheme: :https} = conn) do
    {key, value} = @hsts_header
    put_resp_header(conn, key, value)
  end

  defp maybe_set_hsts(conn), do: conn

  defp browser_request?(conn) do
    case get_req_header(conn, "accept") do
      [accept | _] -> String.contains?(accept, "text/html")
      _ -> false
    end
  end

  defp set_common_headers(conn) do
    Enum.reduce(@common_headers, conn, fn {key, value}, acc ->
      put_resp_header(acc, key, value)
    end)
  end

  defp strip_identifying_headers(conn) do
    Enum.reduce(@stripped_headers, conn, fn header, acc ->
      delete_resp_header(acc, header)
    end)
  end
end
