defmodule MintedWeb.WelcomeControllerTest do
  @moduledoc """
  Round-trip test for the first-visit welcome / phishing-defense
  modal:

    1. A fresh session sees the modal on `/wallet`.
    2. POSTing to `/welcome/dismiss` marks the session welcomed and
       redirects to a safe same-origin path.
    3. A subsequent request with the same session skips the modal.

  Ships alongside the WelcomeController so any future refactor that
  changes the session key, the route, or the redirect-sanitiser
  fails loudly.
  """

  use MintedWeb.IntegrationCase

  # This module exercises the fresh-session (unwelcomed) path, so it
  # discards the pre-welcomed conn provided by MintedWeb.IntegrationCase
  # and builds its own per-test.

  describe "first-visit gating" do
    test "GET /wallet on a fresh session renders the welcome modal" do
      conn =
        Phoenix.ConnTest.build_conn()
        |> Plug.Test.init_test_session(%{})
        |> get("/wallet")

      html = html_response(conn, 200)

      assert html =~ ~s(id="welcome-modal-title")
      assert html =~ "MINTED"
      assert html =~ "Verify this matches your address bar"
      assert html =~ "Phishing clones exist"
    end

    test "POST /welcome/dismiss sets the session flag and redirects to the safe path" do
      conn =
        Phoenix.ConnTest.build_conn()
        |> Plug.Test.init_test_session(%{})
        |> post("/welcome/dismiss", %{"redirect_to" => "/wallet"})

      assert redirected_to(conn) == "/wallet"
      assert get_session(conn, :welcomed) == true
    end

    test "external redirect_to values are rejected in favour of /wallet" do
      conn =
        Phoenix.ConnTest.build_conn()
        |> Plug.Test.init_test_session(%{})
        |> post("/welcome/dismiss", %{"redirect_to" => "https://phishing.example/wallet"})

      assert redirected_to(conn) == "/wallet"
    end

    test "protocol-relative //host paths collapse to /wallet" do
      conn =
        Phoenix.ConnTest.build_conn()
        |> Plug.Test.init_test_session(%{})
        |> post("/welcome/dismiss", %{"redirect_to" => "//evil.example/wallet"})

      assert redirected_to(conn) == "/wallet"
    end

    test "backslash-prefixed paths collapse to /wallet (browsers normalize \\ to /)" do
      # `/\evil.example` slips past the naive `starts_with?("//")`
      # check but every mainstream browser normalizes `\` to `/`
      # when following the redirect — becomes `//evil.example`, a
      # protocol-relative external URL. The welcome surface is the
      # anti-phishing gate; an open redirect here defeats the point.
      for candidate <- [
            "/\\evil.example/wallet",
            "/\\/evil.example",
            "/wallet\\evil.example"
          ] do
        conn =
          Phoenix.ConnTest.build_conn()
          |> Plug.Test.init_test_session(%{})
          |> post("/welcome/dismiss", %{"redirect_to" => candidate})

        assert redirected_to(conn) == "/wallet", "leaked redirect for candidate=#{candidate}"
      end
    end

    test "admin dashboard on a fresh session does not render the modal" do
      conn =
        Phoenix.ConnTest.build_conn()
        |> Plug.Test.init_test_session(%{})
        |> Phoenix.ConnTest.dispatch(MintedAdminWeb.Endpoint, :get, "/admin/dashboard")

      html = html_response(conn, 200)

      refute html =~ ~s(id="welcome-modal-title")
    end

    test "GET /wallet after dismissal does not render the modal" do
      conn =
        Phoenix.ConnTest.build_conn()
        |> Plug.Test.init_test_session(%{"welcomed" => true})
        |> get("/wallet")

      html = html_response(conn, 200)

      refute html =~ ~s(id="welcome-modal-title")
    end
  end
end
