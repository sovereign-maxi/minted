defmodule MintedWeb.MintControllerTest do
  @moduledoc "Unit tests for MintedWeb.MintController."

  use ExUnit.Case, async: false

  import Mox
  import Plug.Conn
  import Phoenix.ConnTest

  alias Minted.Lightning.Manager
  alias Minted.Lightning.PhoenixdMock
  alias Minted.Mint.Quote
  alias Minted.Mint.Services.Quotes
  alias Minted.Mint.Spent

  import Minted.TestHelpers.ProcessHelpers
  import Minted.TestHelpers.StateHelpers

  @endpoint MintedWeb.Endpoint

  setup :clean_state
  setup :set_mox_global
  setup :verify_on_exit!

  setup do
    # Ensure the Minted.Lightning.Manager ETS table exists.
    if :ets.whereis(Minted.Lightning.Manager) == :undefined do
      :ets.new(Minted.Lightning.Manager, [:named_table, :set, :public, read_concurrency: true])
    end

    # Stub Phoenixd calls so Manager doesn't crash during polling.
    stub(PhoenixdMock, :get_incoming_payment, fn _config, _hash -> {:error, :not_found} end)

    # Stub create_invoice for mint quote creation flow.
    stub(PhoenixdMock, :create_invoice, fn _config, amount, _desc, _exp ->
      hash = Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
      {:ok, %{"paymentHash" => hash, "serialized" => "lnbc#{amount}u1p_test"}}
    end)

    # Ensure Manager is running with default name.
    case GenServer.whereis(Manager) do
      nil ->
        {:ok, pid} = Manager.start_link(poll_interval: 60_000)
        on_exit(fn -> safe_stop(pid) end)

      _pid ->
        Manager.clear()
    end

    :ok
  end

  defp json_post(path, body) do
    build_conn()
    |> put_req_header("content-type", "application/json")
    |> post(path, Jason.encode!(body))
  end

  # -- NUT-04: Mint Quote --

  describe "POST /v1/mint/quote" do
    test "creates a mint quote with Lightning invoice" do
      conn = json_post("/v1/mint/quote", %{"amount" => 1000, "unit" => "sat"})

      body = json_response(conn, 200)
      assert is_binary(body["quote"])
      assert is_binary(body["request"])
      # Quote has an invoice attached, so it's UNPAID (invoiced state)
      assert body["state"] == "UNPAID"
      assert is_integer(body["expiry"])
      # request field should contain the bolt11 invoice
      assert body["request"] =~ "lnbc"
    end

    test "rejects non-integer amount" do
      conn = json_post("/v1/mint/quote", %{"amount" => "abc", "outputs" => []})
      json_response(conn, 400)
    end

    test "rejects missing fields" do
      conn = json_post("/v1/mint/quote", %{})
      json_response(conn, 400)
    end

    test "returns error when Lightning is unavailable" do
      expect(PhoenixdMock, :create_invoice, 4, fn _config, _amount, _desc, _exp ->
        {:error, :phoenixd_unreachable}
      end)

      conn = json_post("/v1/mint/quote", %{"amount" => 1000, "unit" => "sat"})
      json_response(conn, 503)
    end
  end

  describe "POST /v1/mint/quote/:id" do
    test "returns 404 for unknown quote" do
      conn = json_post("/v1/mint/quote/nonexistent", %{})

      body = json_response(conn, 404)
      assert body["code"] == 10_010
    end

    test "returns quote state for invoiced quote" do
      create_conn = json_post("/v1/mint/quote", %{"amount" => 100, "unit" => "sat"})
      %{"quote" => quote_id} = json_response(create_conn, 200)

      conn = json_post("/v1/mint/quote/#{quote_id}", %{})

      body = json_response(conn, 200)
      assert body["quote"] == quote_id
      assert body["state"] in ["UNPAID", "PAID", "ISSUED", "EXPIRED"]
    end

    test "rejects mint claim with duplicate blinded messages" do
      create_conn = json_post("/v1/mint/quote", %{"amount" => 8, "unit" => "sat"})
      %{"quote" => quote_id} = json_response(create_conn, 200)

      # Transition quote to paid state so claim_paid_quote path is reached.
      {:ok, _} =
        Quotes.update_quote(quote_id, &Quote.mark_paid(&1, "test_payment_hash"))

      b_prime = :crypto.strong_rand_bytes(33) |> Base.encode16(case: :lower)
      output = %{"amount" => 4, "id" => "00abcdef", "B_" => b_prime}

      conn = json_post("/v1/mint/quote/#{quote_id}", %{"outputs" => [output, output]})

      body = json_response(conn, 400)
      assert body["code"] == 10_008
      assert body["detail"] == "Duplicate blinded messages"
    end
  end

  # -- NUT-05: Melt Quote --

  describe "POST /v1/melt/quote" do
    test "creates a melt quote for valid bolt11" do
      conn = json_post("/v1/melt/quote", %{"request" => "lnbc1000n1dummy", "unit" => "sat"})

      body = json_response(conn, 200)
      assert is_binary(body["quote"])
      assert body["state"] in ["UNPAID", "PAID"]
      assert is_integer(body["amount"])
    end

    test "rejects missing request" do
      conn = json_post("/v1/melt/quote", %{"unit" => "sat"})
      json_response(conn, 400)
    end

    test "rejects invalid unit" do
      conn = json_post("/v1/melt/quote", %{"request" => "lnbc1000n1dummy", "unit" => "usd"})
      json_response(conn, 400)
    end
  end

  # -- NUT-03: Swap --

  describe "POST /v1/swap" do
    test "rejects missing inputs/outputs" do
      conn = json_post("/v1/swap", %{})
      json_response(conn, 400)
    end

    test "rejects invalid proof format" do
      conn = json_post("/v1/swap", %{"inputs" => [%{}], "outputs" => [%{}]})

      body = json_response(conn, 400)
      assert body["code"] == 40_001
    end

    test "rejects swap with duplicate blinded messages in outputs" do
      secret = :crypto.strong_rand_bytes(32) |> Base.encode16(case: :lower)
      c = :crypto.strong_rand_bytes(33) |> Base.encode16(case: :lower)
      input = %{"amount" => 8, "id" => "00abcdef", "secret" => secret, "C" => c}

      b_prime = :crypto.strong_rand_bytes(33) |> Base.encode16(case: :lower)
      output = %{"amount" => 4, "id" => "00abcdef", "B_" => b_prime}

      conn = json_post("/v1/swap", %{"inputs" => [input], "outputs" => [output, output]})

      body = json_response(conn, 400)
      assert body["code"] == 10_008
      assert body["detail"] == "Duplicate blinded messages"
    end
  end

  # -- NUT-07: Check --

  describe "POST /v1/check" do
    test "checks token states" do
      # Random Y hex that was never spent.
      y_hex = :crypto.strong_rand_bytes(33) |> Base.encode16(case: :lower)

      conn = json_post("/v1/check", %{"Ys" => [y_hex]})

      body = json_response(conn, 200)
      assert [%{"Y" => ^y_hex, "state" => "UNSPENT", "witness" => nil}] = body["states"]
    end

    test "returns SPENT for spent tokens" do
      # Mark a secret as spent — this also populates the Y-index.
      secret = :crypto.strong_rand_bytes(32)
      Spent.mark_spent(secret, "test-keyset")

      # Compute Y = hash_to_curve(secret), which is what NUT-07 clients send
      {:ok, y} = Cashew.hash_to_curve(secret)
      y_hex = Base.encode16(y, case: :lower)

      conn = json_post("/v1/check", %{"Ys" => [y_hex]})

      body = json_response(conn, 200)
      assert [%{"Y" => ^y_hex, "state" => "SPENT", "witness" => nil}] = body["states"]
    end

    test "rejects missing Ys" do
      conn = json_post("/v1/check", %{})
      json_response(conn, 400)
    end
  end

  # -- NUT-05: Melt --

  describe "POST /v1/melt/quote/:id" do
    test "rejects missing inputs" do
      conn = json_post("/v1/melt/quote/some-id", %{})
      json_response(conn, 400)
    end

    test "returns 404 for unknown quote with valid inputs" do
      conn = json_post("/v1/melt/quote/nonexistent", %{"inputs" => []})

      body = json_response(conn, 404)
      assert body["code"] == 10_010
    end

    test "rejects melt with oversized input batch" do
      oversized_inputs =
        List.duplicate(%{"amount" => 1, "id" => "00ab", "secret" => "aa", "C" => "bb"}, 1001)

      conn = json_post("/v1/melt/quote/some-id", %{"inputs" => oversized_inputs})

      body = json_response(conn, 400)
      assert body["code"] == 40_003
      assert body["detail"] == "Batch too large"
    end
  end
end
