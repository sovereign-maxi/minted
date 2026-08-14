defmodule Minted.Lightning.Settlement.ResolverIntegrationTest do
  @moduledoc """
  Integration tests for the SettlementResolver GenServer.

  Verifies that settlement_unknown quotes are automatically resolved
  by polling Phoenixd for payment status.
  """

  use Minted.IntegrationCase

  import Mox
  import Minted.TestHelpers.ProcessHelpers
  import Minted.TestHelpers.WalletHelpers

  alias Minted.Lightning.PhoenixdMock
  alias Minted.Lightning.Settlement.Resolver
  alias Minted.Mint.{Facade, Keyset, Quote}
  alias Minted.Mint.Services.Quotes, as: QuotesService

  setup :set_mox_global
  setup :verify_on_exit!

  setup do
    # Always generate a fresh keyset to guarantee valid private keys
    keyset = Keyset.generate()
    store_keyset(keyset)

    # Stub other Phoenixd calls that may fire during test
    stub(PhoenixdMock, :get_incoming_payment, fn _c, _h -> {:error, :not_found} end)
    stub(PhoenixdMock, :get_balance, fn _c -> {:ok, %{"balanceSat" => 100_000, "feeCreditSat" => 0}} end)
    stub(PhoenixdMock, :get_info, fn _c -> {:ok, %{"nodeId" => "test"}} end)

    {:ok, keyset: keyset}
  end

  defp create_settlement_unknown_quote(tokens, keyset, ln_payment_hash) do
    quote = Quote.new_melt(Enum.sum(Enum.map(tokens, & &1.amount)), 0, "lnbc100n1test")

    quote = %{
      quote
      | status: :settlement_unknown,
        paying_since: DateTime.add(DateTime.utc_now(), -900, :second),
        melt_context: %{
          ln_payment_hash: ln_payment_hash,
          tokens: tokens,
          keyset_id: keyset.id
        }
    }

    :ok = QuotesService.store_quote(quote)
    quote
  end

  describe "resolve settled payment" do
    test "commits tokens and marks quote claimed when phoenixd says settled",
         %{keyset: keyset} do
      tokens = build_valid_tokens(keyset, [4, 8])
      hash = :crypto.strong_rand_bytes(32)

      {:ok, _} = Facade.verify_and_reserve(tokens, keyset)
      quote = create_settlement_unknown_quote(tokens, keyset, hash)

      expect(PhoenixdMock, :get_outgoing_payment_by_hash, fn _config, ^hash ->
        {:ok, %{"isPaid" => true, "preimage" => "abc123def456", "routingFeeSat" => 1}}
      end)

      {:ok, pid} = Resolver.start_link(poll_interval_ms: :timer.hours(1), min_age_ms: 0)
      on_exit(fn -> safe_stop(pid) end)

      Resolver.resolve_now(pid)

      {:ok, resolved} = Facade.get_quote(quote.id)
      assert resolved.status == :claimed

      Enum.each(tokens, fn token ->
        assert Facade.spent?(token.secret)
      end)
    end
  end

  describe "resolve failed payment" do
    test "releases tokens and reverts quote when phoenixd says definitively failed",
         %{keyset: keyset} do
      tokens = build_valid_tokens(keyset, [16])
      hash = :crypto.strong_rand_bytes(32)

      {:ok, _} = Facade.verify_and_reserve(tokens, keyset)
      quote = create_settlement_unknown_quote(tokens, keyset, hash)

      # Phoenixd's failed-payment shape: `completedAt` set AND
      # `isPaid: false`. The resolver now checks `completedAt` first
      # so this classifies as :failed (was `:pending` under the old
      # clause order).
      expect(PhoenixdMock, :get_outgoing_payment_by_hash, fn _config, ^hash ->
        {:ok, %{"isPaid" => false, "completedAt" => 1_700_000_000_000}}
      end)

      {:ok, pid} = Resolver.start_link(poll_interval_ms: :timer.hours(1), min_age_ms: 0)
      on_exit(fn -> safe_stop(pid) end)

      Resolver.resolve_now(pid)

      {:ok, resolved} = Facade.get_quote(quote.id)
      assert resolved.status == :invoiced
      assert resolved.melt_context == nil

      Enum.each(tokens, fn token ->
        refute Facade.spent?(token.secret)
      end)
    end

    test "HOLDS the reservation on any HTTP error (never releases on 4xx/5xx)",
         %{keyset: keyset} do
      tokens = build_valid_tokens(keyset, [16])
      hash = :crypto.strong_rand_bytes(32)

      {:ok, _} = Facade.verify_and_reserve(tokens, keyset)
      quote = create_settlement_unknown_quote(tokens, keyset, hash)

      # A 404 from the node used to release the reservation
      # (the old unsafe fail-open branch). It MUST now escalate —
      # the payment may have settled and the record been purged.
      expect(PhoenixdMock, :get_outgoing_payment_by_hash, fn _config, ^hash ->
        {:error, {:http_error, 404, "not found"}}
      end)

      {:ok, pid} = Resolver.start_link(poll_interval_ms: :timer.hours(1), min_age_ms: 0)
      on_exit(fn -> safe_stop(pid) end)

      Resolver.resolve_now(pid)

      {:ok, still_unknown} = Facade.get_quote(quote.id)
      assert still_unknown.status == :settlement_unknown

      Enum.each(tokens, fn token ->
        assert Facade.spent?(token.secret)
      end)
    end
  end

  describe "pending payment" do
    test "leaves quote unchanged when phoenixd says still pending", %{keyset: keyset} do
      tokens = build_valid_tokens(keyset, [8])
      hash = :crypto.strong_rand_bytes(32)

      {:ok, _} = Facade.verify_and_reserve(tokens, keyset)
      quote = create_settlement_unknown_quote(tokens, keyset, hash)

      stub(PhoenixdMock, :get_outgoing_payment_by_hash, fn _config, _hash ->
        {:ok, %{"isPaid" => false}}
      end)

      {:ok, pid} = Resolver.start_link(poll_interval_ms: :timer.hours(1), min_age_ms: 0)
      on_exit(fn -> safe_stop(pid) end)

      Resolver.resolve_now(pid)

      {:ok, still_unknown} = Facade.get_quote(quote.id)
      assert still_unknown.status == :settlement_unknown

      Enum.each(tokens, fn token ->
        assert Facade.spent?(token.secret)
      end)
    end
  end

  describe "min age gate" do
    test "skips quotes that are too recent", %{keyset: keyset} do
      tokens = build_valid_tokens(keyset, [8])
      hash = :crypto.strong_rand_bytes(32)

      {:ok, _} = Facade.verify_and_reserve(tokens, keyset)

      quote = Quote.new_melt(8, 0, "lnbc100n1test")

      quote = %{
        quote
        | status: :settlement_unknown,
          paying_since: DateTime.utc_now(),
          melt_context: %{ln_payment_hash: hash, tokens: tokens, keyset_id: keyset.id}
      }

      :ok = QuotesService.store_quote(quote)

      # No expectation — if called, Mox will fail.
      {:ok, pid} = Resolver.start_link(poll_interval_ms: :timer.hours(1), min_age_ms: 600_000)
      on_exit(fn -> safe_stop(pid) end)

      Resolver.resolve_now(pid)

      {:ok, still_unknown} = Facade.get_quote(quote.id)
      assert still_unknown.status == :settlement_unknown
    end
  end

  describe "missing melt context" do
    test "skips quotes without an ln_payment_hash gracefully" do
      quote = Quote.new_melt(100, 0, "lnbc100n1test")

      quote = %{
        quote
        | status: :settlement_unknown,
          paying_since: DateTime.add(DateTime.utc_now(), -900, :second)
      }

      :ok = QuotesService.store_quote(quote)

      {:ok, pid} = Resolver.start_link(poll_interval_ms: :timer.hours(1), min_age_ms: 0)
      on_exit(fn -> safe_stop(pid) end)

      Resolver.resolve_now(pid)

      {:ok, still_unknown} = Facade.get_quote(quote.id)
      assert still_unknown.status == :settlement_unknown
    end
  end

  describe "wallet-path (multi-keyset) melt contexts" do
    test "commits across keyset groups when phoenixd says settled", %{keyset: keyset} do
      keyset2 = Keyset.generate()
      store_keyset(keyset2)

      tokens_a = build_valid_tokens(keyset, [4])
      tokens_b = build_valid_tokens(keyset2, [8])
      hash = :crypto.strong_rand_bytes(32)

      {:ok, _} = Facade.verify_and_reserve(tokens_a, keyset)
      {:ok, _} = Facade.verify_and_reserve(tokens_b, keyset2)

      quote = Quote.new_melt(12, 0, "lnbc120n1test")

      quote = %{
        quote
        | status: :settlement_unknown,
          paying_since: DateTime.add(DateTime.utc_now(), -900, :second),
          melt_context: %{
            ln_payment_hash: hash,
            groups: [{keyset.id, tokens_a}, {keyset2.id, tokens_b}]
          }
      }

      :ok = QuotesService.store_quote(quote)

      expect(PhoenixdMock, :get_outgoing_payment_by_hash, fn _config, ^hash ->
        {:ok, %{"isPaid" => true, "preimage" => "abc123def456", "routingFeeSat" => 1}}
      end)

      {:ok, pid} = Resolver.start_link(poll_interval_ms: :timer.hours(1), min_age_ms: 0)
      on_exit(fn -> safe_stop(pid) end)

      Resolver.resolve_now(pid)

      {:ok, resolved} = Facade.get_quote(quote.id)
      assert resolved.status == :claimed

      Enum.each(tokens_a ++ tokens_b, fn token ->
        assert Facade.spent?(token.secret)
      end)
    end

    test "releases across keyset groups when phoenixd says definitively failed", %{keyset: keyset} do
      keyset2 = Keyset.generate()
      store_keyset(keyset2)

      tokens_a = build_valid_tokens(keyset, [16])
      tokens_b = build_valid_tokens(keyset2, [32])
      hash = :crypto.strong_rand_bytes(32)

      {:ok, _} = Facade.verify_and_reserve(tokens_a, keyset)
      {:ok, _} = Facade.verify_and_reserve(tokens_b, keyset2)

      quote = Quote.new_melt(48, 0, "lnbc480n1test")

      quote = %{
        quote
        | status: :settlement_unknown,
          paying_since: DateTime.add(DateTime.utc_now(), -900, :second),
          melt_context: %{
            ln_payment_hash: hash,
            groups: [{keyset.id, tokens_a}, {keyset2.id, tokens_b}]
          }
      }

      :ok = QuotesService.store_quote(quote)

      expect(PhoenixdMock, :get_outgoing_payment_by_hash, fn _config, ^hash ->
        {:ok, %{"isPaid" => false, "completedAt" => 1_700_000_000_000}}
      end)

      {:ok, pid} = Resolver.start_link(poll_interval_ms: :timer.hours(1), min_age_ms: 0)
      on_exit(fn -> safe_stop(pid) end)

      Resolver.resolve_now(pid)

      {:ok, resolved} = Facade.get_quote(quote.id)
      assert resolved.status == :invoiced

      Enum.each(tokens_a ++ tokens_b, fn token ->
        refute Facade.spent?(token.secret)
      end)
    end
  end
end
