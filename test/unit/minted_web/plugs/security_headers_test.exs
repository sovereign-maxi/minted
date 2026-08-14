defmodule MintedWeb.Plugs.SecurityHeadersTest do
  @moduledoc "Unit tests for MintedWeb.Plugs.SecurityHeaders."

  use ExUnit.Case, async: true

  alias MintedWeb.Plugs.SecurityHeaders

  test "sets security headers" do
    conn =
      Plug.Test.conn(:get, "/v1/info")
      |> SecurityHeaders.call(SecurityHeaders.init([]))
      |> send_test_resp()

    assert get_resp_header(conn, "content-security-policy") == [
             "default-src 'none'; frame-ancestors 'none'"
           ]

    assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
    assert get_resp_header(conn, "x-frame-options") == ["DENY"]
    assert get_resp_header(conn, "cache-control") == ["no-store"]
    assert get_resp_header(conn, "referrer-policy") == ["no-referrer"]
  end

  test "emits HSTS only on HTTPS requests" do
    http_conn =
      Plug.Test.conn(:get, "/v1/info")
      |> SecurityHeaders.call(SecurityHeaders.init([]))
      |> send_test_resp()

    assert get_resp_header(http_conn, "strict-transport-security") == []

    https_conn =
      Plug.Test.conn(:get, "/v1/info")
      |> Map.put(:scheme, :https)
      |> SecurityHeaders.call(SecurityHeaders.init([]))
      |> send_test_resp()

    assert get_resp_header(https_conn, "strict-transport-security") == [
             "max-age=63072000; includeSubDomains"
           ]
  end

  test "strips identifying headers" do
    conn =
      Plug.Test.conn(:get, "/v1/info")
      |> Plug.Conn.put_resp_header("server", "Cowboy")
      |> Plug.Conn.put_resp_header("x-powered-by", "Phoenix")
      |> Plug.Conn.put_resp_header("x-request-id", "abc123")
      |> SecurityHeaders.call(SecurityHeaders.init([]))
      |> send_test_resp()

    assert get_resp_header(conn, "server") == []
    assert get_resp_header(conn, "x-powered-by") == []
    assert get_resp_header(conn, "x-request-id") == []
  end

  defp get_resp_header(conn, key) do
    Plug.Conn.get_resp_header(conn, key)
  end

  defp send_test_resp(conn) do
    if conn.state == :sent do
      conn
    else
      Plug.Conn.send_resp(conn, 200, "ok")
    end
  end
end
