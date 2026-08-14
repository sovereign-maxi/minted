defmodule Minted.Mint.House.FacadeIntegrationTest do
  @moduledoc """
  Integration tests for `Minted.Mint.House.Facade` against the
  application-supervised store. Covers the arithmetic
  (earned/drawn/withdrawable/half-cap), guard checks, WAL persistence
  through the request lifecycle, and idempotency of the ETS
  in-flight register.
  """

  use Minted.IntegrationCase

  alias Minted.Events.House, as: HouseEvents
  alias Minted.Mint.House.Facade
  alias Minted.Reserves.Trackers.Fees

  describe "earned/0" do
    test "starts at zero" do
      assert Facade.earned() == 0
    end

    test "reflects fees restored via the tracker" do
      :ok = Fees.restore_counters(10_000)
      assert Facade.earned() == 10_000
    end
  end

  describe "drawn/0 + withdrawable/0" do
    test "both start at zero" do
      assert Facade.drawn() == 0
      assert Facade.withdrawable() == 0
    end

    test "withdrawable follows earned when nothing has been drawn" do
      :ok = Fees.restore_counters(50_000)
      assert Facade.withdrawable() == 50_000
      assert Facade.drawn() == 0
    end
  end

  describe "max_single_request/0 (half-cap rule)" do
    test "is zero when withdrawable is zero" do
      assert Facade.max_single_request() == 0
    end

    test "is exactly half of withdrawable" do
      :ok = Fees.restore_counters(100_000)
      assert Facade.max_single_request() == 50_000
    end

    test "rounds down on odd balance (integer division)" do
      :ok = Fees.restore_counters(100_001)
      assert Facade.max_single_request() == 50_000
    end
  end

  describe "request_withdrawal/2" do
    test "accepts a valid request and returns the event" do
      :ok = Fees.restore_counters(100_000)

      assert {:ok, %HouseEvents.WithdrawalRequested{} = event} =
               Facade.request_withdrawal(40_000, "lnbc...")

      assert event.amount_sats == 40_000
      assert event.invoice == "lnbc..."
      assert is_binary(event.request_id)
      assert Facade.in_flight() == 40_000
    end

    test "rejects below-minimum requests" do
      :ok = Fees.restore_counters(100_000)
      assert {:error, :below_minimum} = Facade.request_withdrawal(500, "lnbc...")
      assert Facade.in_flight() == 0
    end

    test "rejects requests that exceed withdrawable" do
      :ok = Fees.restore_counters(10_000)
      assert {:error, :insufficient_withdrawable} = Facade.request_withdrawal(20_000, "lnbc...")
      assert Facade.in_flight() == 0
    end

    test "rejects requests that exceed the half-cap ceiling" do
      :ok = Fees.restore_counters(100_000)
      assert {:error, :half_cap_exceeded} = Facade.request_withdrawal(60_000, "lnbc...")
      assert Facade.in_flight() == 0
    end

    test "half-cap accounts for in-flight requests (no double-spend race)" do
      :ok = Fees.restore_counters(100_000)

      # First request: 40k. Withdrawable becomes 60k. Half-cap becomes 30k.
      assert {:ok, _} = Facade.request_withdrawal(40_000, "lnbc-a")
      assert Facade.withdrawable() == 60_000
      assert Facade.max_single_request() == 30_000

      # Second request for the SAME amount is now blocked.
      assert {:error, :half_cap_exceeded} = Facade.request_withdrawal(40_000, "lnbc-b")
    end
  end

  describe "complete_withdrawal/2" do
    test "increments drawn (amount + routing fee) + drops in-flight + reduces withdrawable" do
      :ok = Fees.restore_counters(100_000)
      {:ok, event} = Facade.request_withdrawal(40_000, "lnbc...")

      assert :ok = Facade.complete_withdrawal(event.request_id, 5)

      # Routing fee (5) drains the same channel balance that backs
      # user ecash, so it counts against drawn / withdrawable too.
      assert Facade.drawn() == 40_005
      assert Facade.in_flight() == 0
      assert Facade.withdrawable() == 59_995
    end

    test "returns :not_found for an unknown request_id" do
      assert {:error, :not_found} = Facade.complete_withdrawal("never-requested")
    end
  end

  describe "reject_withdrawal/2" do
    test "drops in-flight + restores withdrawable (no drawn increment)" do
      :ok = Fees.restore_counters(100_000)
      {:ok, event} = Facade.request_withdrawal(40_000, "lnbc...")

      assert :ok = Facade.reject_withdrawal(event.request_id, :payment_failed)

      assert Facade.drawn() == 0
      assert Facade.in_flight() == 0
      assert Facade.withdrawable() == 100_000
    end

    test "returns :not_found for an unknown request_id" do
      assert {:error, :not_found} = Facade.reject_withdrawal("never-requested", :payment_failed)
    end
  end

  describe "counter durability" do
    test "rebuilds :total_house_withdrawn from WAL when counter is stale" do
      # The WAL file persists across `mix test` runs (documented in
      # AGENT.md), so the sum from :house_withdrawal_completed entries
      # includes ALL prior test-run entries. Capture the pre-test WAL
      # sum and assert the DELTA matches, not the absolute value.
      pre_test_wal_sum = wal_completed_sum()

      :ok = Fees.restore_counters(200_000)

      {:ok, e1} = Facade.request_withdrawal(50_000, "lnbc-a")
      :ok = Facade.complete_withdrawal(e1.request_id, 0)

      {:ok, e2} = Facade.request_withdrawal(30_000, "lnbc-b")
      :ok = Facade.complete_withdrawal(e2.request_id, 0)

      # Sanity: drawn reflects the two new completions on top of any
      # counter state carried across the DETS file.
      assert Facade.drawn() >= 80_000

      # Simulate the crash scenario: Recovery zeroed the counter, or
      # a crash landed between WAL write and Locker.Counter.increment.
      Locker.Counter.reset(Minted.Reserves.FeeCounter)
      assert Facade.drawn() == 0
      # Earned also got zeroed — restore for the invariant check.
      :ok = Fees.restore_counters(200_000)

      # Restart House.Store: WAL replay's rebuild pass restores drawn
      # to the exact sum of :house_withdrawal_completed entries.
      :ok = GenServer.stop(Minted.Mint.House.Store)

      # Sync on the supervisor: a call blocks until the supervisor has
      # processed the exit signal (FIFO) and completed the replacement
      # child's init/1. No timing sleep — no race.
      _ = Supervisor.which_children(Minted.Mint.Supervisor)

      # Post-rebuild counter equals the pre-test WAL sum + the 80k of
      # completions we appended during this test.
      assert Facade.drawn() == pre_test_wal_sum + 80_000
    end

    defp wal_completed_sum do
      {:ok, entries} = Locker.WAL.read_all(Minted.Storage.WAL)

      # Mirror the House.Store rebuild: routing fee drains channel
      # balance too, so it counts against drawn.
      Enum.reduce(entries, 0, fn
        %Locker.WAL.Entry{
          type: :house_withdrawal_completed,
          payload: %{amount_sats: n, fee_sats: f}
        },
        acc
        when is_integer(n) and is_integer(f) ->
          acc + n + f

        %Locker.WAL.Entry{type: :house_withdrawal_completed, payload: %{amount_sats: n}}, acc
        when is_integer(n) ->
          acc + n

        _, acc ->
          acc
      end)
    end
  end

  describe "invariants across the full lifecycle" do
    test "earned = drawn + withdrawable + in_flight at all times" do
      :ok = Fees.restore_counters(200_000)
      assert Facade.earned() == Facade.drawn() + Facade.withdrawable() + Facade.in_flight()

      {:ok, e1} = Facade.request_withdrawal(50_000, "lnbc-a")
      assert Facade.earned() == Facade.drawn() + Facade.withdrawable() + Facade.in_flight()

      :ok = Facade.complete_withdrawal(e1.request_id, 0)
      assert Facade.earned() == Facade.drawn() + Facade.withdrawable() + Facade.in_flight()

      {:ok, e2} = Facade.request_withdrawal(30_000, "lnbc-b")
      :ok = Facade.reject_withdrawal(e2.request_id, :no_route)
      assert Facade.earned() == Facade.drawn() + Facade.withdrawable() + Facade.in_flight()
    end
  end
end
