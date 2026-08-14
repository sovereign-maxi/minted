defmodule MintedWeb.ReservesControllerIntegrationTest do
  @moduledoc "Integration tests for reserves API endpoint responses."

  use MintedWeb.IntegrationCase

  import Minted.TestHelpers.ProcessHelpers

  setup do
    # Ensure at least one proof exists before testing the API.
    Vault.Generator.generate_now()
    await_condition(fn -> Vault.Generator.latest() != nil end)
    :ok
  end

  describe "GET /v1/reserves" do
    test "returns current reserve proof" do
      conn = build_conn() |> get("/v1/reserves")

      body = json_response(conn, 200)
      assert is_number(body["ratio"])
      assert is_integer(body["held"])
      assert is_integer(body["outstanding"])
    end
  end

  describe "GET /v1/reserves/history" do
    test "returns paginated history" do
      conn = build_conn() |> get("/v1/reserves/history")

      body = json_response(conn, 200)
      assert is_list(body["proofs"])
      assert body["limit"] == 20
    end

    test "respects limit parameter" do
      conn = build_conn() |> get("/v1/reserves/history?limit=5")

      body = json_response(conn, 200)
      assert body["limit"] == 5
    end

    test "clamps limit to 1..100" do
      conn = build_conn() |> get("/v1/reserves/history?limit=200")
      assert json_response(conn, 200)["limit"] == 100

      conn = build_conn() |> get("/v1/reserves/history?limit=0")
      assert json_response(conn, 200)["limit"] == 1
    end
  end
end
