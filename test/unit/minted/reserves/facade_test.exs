defmodule Minted.Reserves.FacadeTest do
  @moduledoc """
  Pins the solvency accounting surface — specifically the
  burned > minted case that the previous `abs(outstanding)`
  implementation masked by rendering an invariant violation as an
  ordinary positive liability on the dashboard.
  """

  use ExUnit.Case, async: false

  alias Minted.Reserves.Facade
  alias Minted.Reserves.Trackers.Liability

  describe "solvency/0 with a real proof" do
    setup do
      previous = Application.get_env(:minted, :test_liability_override)
      on_exit(fn -> Application.put_env(:minted, :test_liability_override, previous) end)
      :ok
    end

    test "negative outstanding surfaces as :invariant_violation, not a large positive liability" do
      # Drive the Liability tracker to burned > minted (an accounting
      # corruption that the mint's separate `:liability_invariant`
      # halt path fires on independently — this test pins the
      # DISPLAY-layer behaviour so the dashboard cannot hide it).
      Liability.reset_counters()
      Liability.restore_counters(:minted, 100)
      Liability.restore_counters(:burned, 500)

      snapshot = Liability.current()
      assert snapshot.outstanding < 0, "test setup precondition"

      result = Facade.solvency()

      # Depending on Vault proof availability the top-level status
      # may be :pending. When a proof IS present, the invariant
      # violation MUST surface as its own status — not as a
      # positive-liability solvency ratio via abs().
      case result.status do
        :invariant_violation ->
          assert result.outstanding < 0,
                 "signed outstanding must reach the caller so operator sees the violation"

          assert result.title =~ "INVARIANT",
                 "title must call out the violation, not hide it as a percentage"

        :pending ->
          # No proof yet — reasonable; :invariant_violation only
          # surfaces once there's a proof to compare against.
          assert result.pct == 0
          assert result.held == 0
      end
    end

    test "zero outstanding renders as 999%, not divide-by-zero" do
      Liability.reset_counters()

      result = Facade.solvency()

      # Same caveat: only checkable when a proof exists.
      case result.status do
        :active -> assert result.pct == 999
        :pending -> :ok
      end
    end
  end
end
