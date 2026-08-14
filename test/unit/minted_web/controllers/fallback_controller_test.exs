defmodule MintedWeb.FallbackControllerTest do
  @moduledoc "Unit tests for MintedWeb.FallbackController."

  use ExUnit.Case, async: true

  alias MintedWeb.FallbackController

  # Helper to build a minimal conn for testing the fallback controller.
  # Phoenix.Controller.json/2 requires :phoenix_format and :phoenix_endpoint.
  defp build_conn do
    Plug.Test.conn(:get, "/")
    |> Plug.Conn.put_private(:phoenix_format, "json")
    |> Plug.Conn.put_private(:phoenix_endpoint, MintedWeb.Endpoint)
    |> Plug.Conn.put_resp_content_type("application/json")
  end

  # --- 400 Bad Request ---

  describe "400 errors" do
    @errors_400 [
      {:invalid_amount, 10_001, "Invalid amount"},
      {:below_minimum, 10_002, "Amount below minimum"},
      {:above_maximum, 10_003, "Amount above maximum"},
      {:invalid_signature, 10_004, "Invalid token signature"},
      {:empty_batch, 10_005, "Empty token batch"},
      {:empty_swap, 30_002, "Empty swap"},
      {:invalid_request, 40_001, "Malformed request body"},
      {:denomination_not_found, 10_006, "Unknown denomination"},
      {:invalid_transition, 40_002, "Invalid state transition"},
      {:insufficient_tokens, 10_007, "Insufficient token value"},
      {:invalid_bolt11, 20_010, "Invalid Lightning invoice"},
      {:keyset_not_active, 10_012, "Keyset is not active"},
      {:payment_not_verified, 10_013, "Payment not verified"},
      {:value_mismatch, 30_001, "Input value does not equal output value"}
    ]

    for {error, code, detail_prefix} <- @errors_400 do
      test "#{error} returns 400 with code #{code}" do
        conn = FallbackController.call(build_conn(), {:error, unquote(error)})
        assert conn.status == 400
        body = Jason.decode!(conn.resp_body)
        assert body["code"] == unquote(code)
        assert body["detail"] =~ unquote(detail_prefix)
      end
    end

    test "amount_mismatch (nested tuple) returns 400 with code 30001" do
      conn = FallbackController.call(build_conn(), {:error, {:amount_mismatch, 100, 50}})
      assert conn.status == 400
      body = Jason.decode!(conn.resp_body)
      assert body["code"] == 30_001
    end

    test "bolt11_parse_error returns 400 with code 20011" do
      conn = FallbackController.call(build_conn(), {:error, {:bolt11_parse_error, :bad_checksum}})
      assert conn.status == 400
      body = Jason.decode!(conn.resp_body)
      assert body["code"] == 20_011
    end
  end

  # --- 404 Not Found ---

  describe "404 errors" do
    @errors_404 [
      {:not_found, 40_004, "Not found"},
      {:quote_not_found, 10_010, "Quote not found"},
      {:keyset_not_found, 10_011, "Keyset not found"}
    ]

    for {error, code, detail_prefix} <- @errors_404 do
      test "#{error} returns 404 with code #{code}" do
        conn = FallbackController.call(build_conn(), {:error, unquote(error)})
        assert conn.status == 404
        body = Jason.decode!(conn.resp_body)
        assert body["code"] == unquote(code)
        assert body["detail"] =~ unquote(detail_prefix)
      end
    end
  end

  # --- 409 Conflict ---

  describe "409 errors" do
    test "already_spent returns 409 with code 10020" do
      conn = FallbackController.call(build_conn(), {:error, :already_spent})
      assert conn.status == 409
      body = Jason.decode!(conn.resp_body)
      assert body["code"] == 10_020
    end

    test "double_spend (3-tuple) returns 409 with code 10020" do
      conn = FallbackController.call(build_conn(), {:error, :double_spend, ["hash1"]})
      assert conn.status == 409
      body = Jason.decode!(conn.resp_body)
      assert body["code"] == 10_020
    end
  end

  # --- 410 Gone ---

  describe "410 errors" do
    test "quote_expired returns 410 with code 10030" do
      conn = FallbackController.call(build_conn(), {:error, :quote_expired})
      assert conn.status == 410
      body = Jason.decode!(conn.resp_body)
      assert body["code"] == 10_030
    end
  end

  # --- 503 Service Unavailable ---

  describe "503 errors" do
    @errors_503 [
      {:insufficient_liquidity, 20_001, "Insufficient liquidity"},
      {:payment_failed, 20_002, "Lightning payment failed"},
      {:phoenixd_unreachable, 20_003, "Lightning service unavailable"},
      {:too_many_concurrent, 20_004, "Too many concurrent payments"}
    ]

    for {error, code, detail_prefix} <- @errors_503 do
      test "#{error} returns 503 with code #{code}" do
        conn = FallbackController.call(build_conn(), {:error, unquote(error)})
        assert conn.status == 503
        body = Jason.decode!(conn.resp_body)
        assert body["code"] == unquote(code)
        assert body["detail"] =~ unquote(detail_prefix)
      end
    end
  end

  # --- 500 Catch-all ---

  describe "catch-all" do
    test "unknown error returns 500 with code 0" do
      conn = FallbackController.call(build_conn(), {:error, :some_unknown_error})
      assert conn.status == 500
      body = Jason.decode!(conn.resp_body)
      assert body["code"] == 0
      assert body["detail"] =~ "Internal server error"
    end
  end

  # --- Response format ---

  describe "response format" do
    test "all responses include detail and code keys" do
      conn = FallbackController.call(build_conn(), {:error, :invalid_amount})
      body = Jason.decode!(conn.resp_body)
      assert Map.has_key?(body, "detail")
      assert Map.has_key?(body, "code")
    end

    test "content type is application/json" do
      conn = FallbackController.call(build_conn(), {:error, :not_found})
      content_type = Plug.Conn.get_resp_header(conn, "content-type")
      assert Enum.any?(content_type, &String.contains?(&1, "application/json"))
    end
  end
end
