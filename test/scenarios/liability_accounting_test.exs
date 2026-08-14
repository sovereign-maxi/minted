defmodule Minted.Scenarios.LiabilityAccountingTest do
  @moduledoc """
  Cross-domain scenario tests for liability accounting invariants:
  minting increases liability, burning decreases it, fees are tracked,
  and minted - burned = outstanding liability.
  """

  use ExUnit.Case, async: false

  @moduletag :scenario

  import Minted.TestHelpers.StateHelpers
  import Minted.TestHelpers.ProcessHelpers
  import Minted.TestHelpers.WalletHelpers

  alias Minted.Events.EventBus
  alias Minted.Events.Mint, as: MintEvents
  alias Minted.Reserves.Trackers.{Fees, Liability}

  setup :clean_state

  setup do
    keyset = get_or_create_test_keyset()
    {:ok, keyset: keyset}
  end

  describe "mint tokens -> liability increases" do
    test "publishing TokensMinted increases liability by exact amount" do
      initial = Liability.current()
      assert initial.minted == 0
      assert initial.outstanding == 0

      # Simulate minting 500 sats
      EventBus.publish(%MintEvents.TokensMinted{
        amount: 500,
        count: 3,
        timestamp: DateTime.utc_now()
      })

      await_condition(fn -> Liability.minted_total() == 500 end)

      state = Liability.current()
      assert state.minted == 500
      assert state.burned == 0
      assert state.outstanding == 500
    end

    test "multiple mint events accumulate correctly" do
      for amount <- [100, 200, 300] do
        EventBus.publish(%MintEvents.TokensMinted{
          amount: amount,
          count: 1,
          timestamp: DateTime.utc_now()
        })
      end

      await_condition(fn -> Liability.minted_total() == 600 end)

      state = Liability.current()
      assert state.minted == 600
      assert state.outstanding == 600
    end
  end

  describe "burn tokens -> liability decreases" do
    test "publishing TokensBurned decreases outstanding liability" do
      # Mint first
      EventBus.publish(%MintEvents.TokensMinted{
        amount: 1000,
        count: 5,
        timestamp: DateTime.utc_now()
      })

      await_condition(fn -> Liability.minted_total() == 1000 end)

      # Burn 400
      EventBus.publish(%MintEvents.TokensBurned{
        amount: 400,
        count: 2,
        timestamp: DateTime.utc_now()
      })

      await_condition(fn -> Liability.burned_total() == 400 end)

      state = Liability.current()
      assert state.minted == 1000
      assert state.burned == 400
      assert state.outstanding == 600
    end
  end

  describe "fee events" do
    test "FeesCollected events increment fee tracker correctly" do
      quote_id = Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)

      EventBus.publish(%MintEvents.FeesCollected{
        amount: 10,
        quote_id: quote_id,
        timestamp: DateTime.utc_now()
      })

      await_condition(fn ->
        fees = Fees.current()
        fees.total_collected == 10 and fees.event_count == 1
      end)

      fees = Fees.current()
      assert fees.total_collected == 10
      assert fees.event_count == 1

      # Second fee event
      EventBus.publish(%MintEvents.FeesCollected{
        amount: 25,
        quote_id: Base.encode16(:crypto.strong_rand_bytes(16), case: :lower),
        timestamp: DateTime.utc_now()
      })

      await_condition(fn ->
        fees = Fees.current()
        fees.total_collected == 35 and fees.event_count == 2
      end)

      fees = Fees.current()
      assert fees.total_collected == 35
      assert fees.event_count == 2
    end
  end

  describe "invariant: minted - burned = outstanding" do
    test "holds after mixed mint and burn operations" do
      operations = [
        {:mint, 256},
        {:mint, 512},
        {:burn, 128},
        {:mint, 64},
        {:burn, 32},
        {:burn, 16},
        {:mint, 1024}
      ]

      expected_minted = 256 + 512 + 64 + 1024
      expected_burned = 128 + 32 + 16
      expected_outstanding = expected_minted - expected_burned

      Enum.each(operations, fn
        {:mint, amount} ->
          EventBus.publish(%MintEvents.TokensMinted{
            amount: amount,
            count: 1,
            timestamp: DateTime.utc_now()
          })

        {:burn, amount} ->
          EventBus.publish(%MintEvents.TokensBurned{
            amount: amount,
            count: 1,
            timestamp: DateTime.utc_now()
          })
      end)

      await_condition(fn ->
        state = Liability.current()
        state.minted == expected_minted and state.burned == expected_burned
      end)

      state = Liability.current()
      assert state.minted == expected_minted
      assert state.burned == expected_burned
      assert state.outstanding == expected_outstanding
      assert state.outstanding == state.minted - state.burned
    end

    test "swap events compensate liability correctly" do
      # Mint some tokens
      EventBus.publish(%MintEvents.TokensMinted{
        amount: 100,
        count: 2,
        timestamp: DateTime.utc_now()
      })

      await_condition(fn -> Liability.minted_total() == 100 end)

      # Swap is modeled as: burn old + mint new (via TokensSwapped which increments minted)
      # and the burn side is handled by TokensBurned from RedemptionService.commit_reservation
      EventBus.publish(%MintEvents.TokensBurned{
        amount: 100,
        count: 2,
        timestamp: DateTime.utc_now()
      })

      EventBus.publish(%MintEvents.TokensSwapped{
        amount: 100,
        count: 4,
        timestamp: DateTime.utc_now()
      })

      await_condition(fn ->
        state = Liability.current()
        state.burned == 100 and state.minted == 200
      end)

      state = Liability.current()
      # minted = 100 (original) + 100 (swap compensation) = 200
      # burned = 100 (from swap commit)
      # outstanding = 200 - 100 = 100 (unchanged, as expected for a swap)
      assert state.minted == 200
      assert state.burned == 100
      assert state.outstanding == 100
      assert state.outstanding == state.minted - state.burned
    end
  end
end
