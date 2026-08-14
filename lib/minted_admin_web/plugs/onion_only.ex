defmodule MintedAdminWeb.Plugs.OnionOnly do
  @moduledoc """
  Refuses any request to the admin endpoint whose Host header is not a
  Tor hidden service address.

  The admin endpoint is intended to be reachable only via its dedicated
  `.onion` hostname. Network-layer enforcement (binding the listener to
  loopback, plus Tor's HiddenServicePort mapping) is the primary control.
  This plug is a defence-in-depth HTTP-layer check that fails closed if
  the listener is ever misconfigured or a reverse proxy ends up exposing
  the endpoint over clearnet.

  In `:prod` the Host header must end in `.onion`, and if an admin onion
  hostname is configured via `:minted, :tor_hostnames` it must match
  exactly. In other environments the plug is a no-op so local
  development against `localhost:4001` keeps working.
  """

  @behaviour Plug

  import Plug.Conn
  require Logger

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    if enforce?() and not allowed_host?(conn.host) do
      Logger.warning("AdminOnionOnly: rejected request with host=#{inspect(conn.host)}")

      conn
      |> send_resp(404, "")
      |> halt()
    else
      conn
    end
  end

  defp enforce? do
    Application.get_env(:minted, :env, :dev) == :prod
  end

  defp allowed_host?(host) when is_binary(host) do
    String.ends_with?(host, ".onion") and matches_configured_onion?(host)
  end

  defp allowed_host?(_), do: false

  defp matches_configured_onion?(host) do
    case Application.get_env(:minted, :tor_hostnames) do
      %{admin: configured} when is_binary(configured) and configured != "" ->
        Plug.Crypto.secure_compare(String.downcase(host), String.downcase(configured))

      _ ->
        # Fail closed in production — reject if no admin hostname configured
        not enforce?()
    end
  end
end
