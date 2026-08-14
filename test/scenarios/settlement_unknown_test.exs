defmodule Minted.Scenarios.SettlementUnknownTest do
  @moduledoc """
  Scenario test for the full settlement_unknown lifecycle:

  1. User deposits and receives tokens (mint)
  2. User initiates withdrawal (melt)
  3. Lightning payment times out
  4. Service returns :settlement_unknown
  5. Tokens remain locked (reserved, not released)
  6. Operator resolves via console (commit or release)
  """

  use ExUnit.Case, async: false

  @moduletag :scenario

  import Mox
  import Minted.TestHelpers.StateHelpers
  import Minted.TestHelpers.WalletHelpers

  alias Minted.Lightning.PhoenixdMock
  alias Minted.Mint.Facade, as: MintFacade
  alias Minted.Wallet.Service

  setup :clean_state
  setup :set_mox_global
  setup :verify_on_exit!

  setup do
    keyset = get_or_create_test_keyset()
    {:ok, keyset: keyset}
  end

  describe "settlement_unknown → operator release" do
    test "tokens can be released by operator after failed payment", %{keyset: keyset} do
      # Build valid tokens
      tokens = build_valid_tokens(keyset, [16, 32])

      # Reserve them (simulating the start of a melt)
      {:ok, _} = MintFacade.verify_and_reserve(tokens, keyset)

      # Verify tokens are now spent (reserved = spent in the spent set)
      Enum.each(tokens, fn token ->
        assert MintFacade.spent?(token.secret)
      end)

      # Operator determines payment failed — release the reservation
      :ok = MintFacade.release_reservation(tokens, keyset)

      # Tokens are now unspent — user can try again
      Enum.each(tokens, fn token ->
        refute MintFacade.spent?(token.secret)
      end)
    end

    test "tokens can be committed by operator after confirmed payment", %{keyset: keyset} do
      # Build valid tokens
      tokens = build_valid_tokens(keyset, [64, 128])

      # Reserve them
      {:ok, _} = MintFacade.verify_and_reserve(tokens, keyset)

      # Operator confirms payment settled — commit the reservation
      :ok = MintFacade.commit_reservation(tokens, keyset)

      # Tokens remain permanently spent
      Enum.each(tokens, fn token ->
        assert MintFacade.spent?(token.secret)
      end)
    end

    test "double-spend prevented after reservation", %{keyset: keyset} do
      tokens = build_valid_tokens(keyset, [16])

      # Reserve
      {:ok, _} = MintFacade.verify_and_reserve(tokens, keyset)

      # Second reserve attempt should fail
      assert {:error, _} = MintFacade.verify_and_reserve(tokens, keyset)
    end
  end

  describe "settlement timeout configuration" do
    @melt_timeout Application.compile_env(:minted, :melt_settlement_timeout_ms, 120_000)

    test "default timeout is 120 seconds" do
      assert @melt_timeout == 120_000
    end
  end

  describe "wallet melt with ambiguous outcome" do
    test "parks the quote for the resolver and holds reservations", %{keyset: keyset} do
      # A second keyset so the melt spans keyset groups.
      keyset2 = Minted.Mint.Keyset.generate()
      store_keyset(keyset2)

      tokens_a = build_valid_tokens(keyset, [8_192, 2_048])
      tokens_b = build_valid_tokens(keyset2, [1_024])
      tokens = tokens_a ++ tokens_b

      # 10_000 sat invoice (lnbc + 100u + 1 + padding for length).
      bolt11 = "lnbc100u1p" <> String.duplicate("x", 60)

      # Phoenixd answers 2xx without a preimage — the executor cannot
      # prove settlement, so the outcome is ambiguous.
      stub(PhoenixdMock, :pay_invoice, fn _config, _bolt11, _amount, _desc, _fee ->
        {:ok, %{"txId" => "opaque"}}
      end)

      stub(Minted.ClockMock, :send_after, fn _pid, _msg, _ms -> :ok end)

      assert {:error, :settlement_unknown} = Service.melt_tokens(bolt11, 0, tokens)

      # Tokens stay reserved — never released on an ambiguous outcome.
      Enum.each(tokens, fn token ->
        assert MintFacade.spent?(token.secret)
      end)

      # The quote is parked in :settlement_unknown carrying per-keyset
      # melt_context groups — the SettlementResolver's handle.
      parked =
        MintFacade.list_quotes_by_status(:settlement_unknown)
        |> Enum.filter(fn q -> q.type == :melt end)

      assert [quote] = parked
      assert %{groups: groups} = quote.melt_context

      grouped_ids = Enum.map(groups, fn {keyset_id, _tokens} -> keyset_id end)
      assert keyset.id in grouped_ids
      assert keyset2.id in grouped_ids
    end
  end
end
