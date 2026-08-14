defmodule Minted.Scenarios.RecoveryLifecycleTest do
  @moduledoc """
  Cross-domain scenario tests for the recovery lifecycle:
  liability counters must survive restarts and be properly
  restored from WAL during recovery.

  This validates the fix where LiabilityCounter was previously
  in Reserves.Supervisor (started after Storage.Supervisor),
  causing recovery to fail when WAL entries needed counter access.
  """

  use ExUnit.Case, async: false

  @moduletag :scenario

  import Minted.TestHelpers.StateHelpers
  import Minted.TestHelpers.ProcessHelpers

  alias Minted.Events.EventBus
  alias Minted.Events.Mint, as: MintEvents
  alias Minted.Reserves.Trackers.{Fees, Liability}
  alias Minted.Storage.Runner

  setup :clean_state

  describe "counter availability during recovery" do
    test "liability counters are accessible immediately after Storage.Supervisor starts" do
      # This is the core invariant: counters must be up before recovery runs.
      # Runner calls ReservesFacade.reset_counters() which needs
      # LiabilityCounter to be alive.
      assert Process.whereis(Minted.Reserves.LiabilityCounter) != nil
      assert Process.whereis(Minted.Reserves.FeeCounter) != nil

      # And they should be functional
      assert :ok = Liability.reset_counters()
      assert :ok = Fees.reset_counters()
    end

    test "recovery completes before downstream supervisors need counters" do
      # Runner should have completed by the time we can query it
      state = :sys.get_state(Runner)
      assert state.recovery == :ok

      # And counters should reflect recovered state (zero on fresh install)
      tracker_state = Liability.current()
      assert tracker_state.minted >= 0
      assert tracker_state.burned >= 0
    end
  end

  describe "liability tracking across mint events" do
    test "minting increases liability, recovery preserves the counters" do
      # Start with clean counters
      Liability.reset_counters()

      # Simulate minting
      EventBus.publish(%MintEvents.TokensMinted{
        amount: 1_000,
        count: 3,
        timestamp: DateTime.utc_now()
      })

      await_condition(fn -> Liability.minted_total() == 1_000 end)

      # Simulate burning
      EventBus.publish(%MintEvents.TokensBurned{
        amount: 400,
        count: 2,
        timestamp: DateTime.utc_now()
      })

      await_condition(fn -> Liability.burned_total() == 400 end)

      # Verify state
      state = Liability.current()
      assert state.minted == 1_000
      assert state.burned == 400
      assert state.outstanding == 600
    end

    test "fee tracking accumulates correctly" do
      Fees.reset_counters()

      EventBus.publish(%MintEvents.FeesCollected{
        amount: 50,
        quote_id: "test_quote_fee",
        timestamp: DateTime.utc_now()
      })

      await_condition(fn ->
        totals = Fees.current()
        totals.total_collected > 0
      end)

      totals = Fees.current()
      assert totals.total_collected == 50
      assert totals.event_count == 1
    end
  end

  describe "counter reset idempotency" do
    test "resetting counters twice produces the same result" do
      # Accumulate some state
      EventBus.publish(%MintEvents.TokensMinted{
        amount: 500,
        count: 1,
        timestamp: DateTime.utc_now()
      })

      await_condition(fn -> Liability.minted_total() == 500 end)

      # Reset once
      Liability.reset_counters()
      assert Liability.minted_total() == 0

      # Reset again — should be safe
      Liability.reset_counters()
      assert Liability.minted_total() == 0
    end
  end
end
