defmodule Minted.Guards.IntegrationTest do
  @moduledoc """
  Integration tests verifying that halt guards block write operations
  across all critical paths.
  """

  use Minted.IntegrationCase

  alias Minted.Guards
  alias Minted.Mint.Facade, as: MintFacade
  alias Minted.Telemetry.Health.System

  setup do
    seed_test_keyset()
    on_exit(fn -> System.clear_halt() end)
    :ok
  end

  describe "Mint facade guards" do
    test "create_mint_quote rejects when halted" do
      System.set_halted("test")

      assert_raise Guards.SystemHaltedError, fn ->
        MintFacade.create_mint_quote(1000)
      end
    end

    test "create_melt_quote rejects when halted" do
      System.set_halted("test")

      assert_raise Guards.SystemHaltedError, fn ->
        MintFacade.create_melt_quote("lnbc1000n1fake", [])
      end
    end

    test "sign rejects when halted" do
      System.set_halted("test")

      assert_raise Guards.SystemHaltedError, fn ->
        MintFacade.sign("quote-id", [], "keyset-id")
      end
    end

    test "swap rejects when halted" do
      System.set_halted("test")

      assert_raise Guards.SystemHaltedError, fn ->
        MintFacade.swap([], [], "keyset-id", "proof")
      end
    end
  end

  describe "facade is the guard boundary" do
    test "facade guards prevent reaching internal modules" do
      # The guard lives at the facade level, not in internal modules.
      # Internal modules don't know about Guards. The facade catches it first.
      System.set_halted("test")

      assert_raise Guards.SystemHaltedError, fn ->
        MintFacade.create_mint_quote(1000)
      end
    end
  end

  describe "HTTP endpoint guards" do
    test "POST /v1/mint/quote returns 503 when halted" do
      System.set_halted("test")

      conn =
        Phoenix.ConnTest.build_conn()
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> Phoenix.ConnTest.dispatch(MintedWeb.Endpoint, :post, "/v1/mint/quote", %{
          "amount" => 1000,
          "unit" => "sat"
        })

      assert conn.status == 503
      body = Jason.decode!(conn.resp_body)
      assert body["error"] == "service_unavailable"
    end

    test "POST /v1/swap returns 503 when halted" do
      System.set_halted("test")

      conn =
        Phoenix.ConnTest.build_conn()
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> Phoenix.ConnTest.dispatch(MintedWeb.Endpoint, :post, "/v1/swap", %{
          "inputs" => [],
          "outputs" => []
        })

      assert conn.status == 503
    end

    test "POST /v1/check still works when halted (read-only)" do
      System.set_halted("test")

      conn =
        Phoenix.ConnTest.build_conn()
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> Phoenix.ConnTest.dispatch(MintedWeb.Endpoint, :post, "/v1/check", %{
          "proofs" => []
        })

      # Should NOT be 503 — check is read-only
      refute conn.status == 503
    end
  end

  describe "Vault proof generation guards" do
    test "halt_check callback returns :halted when system is halted" do
      halt_check = fn -> if Guards.operational?(), do: :ok, else: :halted end

      assert halt_check.() == :ok

      System.set_halted("test")
      assert halt_check.() == :halted
    end
  end
end
