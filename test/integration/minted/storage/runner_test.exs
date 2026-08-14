defmodule Minted.Storage.RunnerIntegrationTest do
  @moduledoc """
  Integration tests for Runner — the GenServer that
  coordinates storage recovery after supervisor children are up.
  """

  use Minted.IntegrationCase

  alias Minted.Storage.Runner

  describe "successful recovery" do
    test "process is alive after startup" do
      pid = Process.whereis(Runner)
      assert pid != nil
      assert Process.alive?(pid)
    end

    test "state contains recovery: :ok after completion" do
      # Runner.init/1 runs Recovery.run synchronously, so by the time
      # Storage.Supervisor.start_link has returned (and therefore by
      # the time this test can run at all) the state is populated.
      state = :sys.get_state(Runner)
      assert state.recovery == :ok
    end
  end

  describe "recovery with liability counters" do
    test "LiabilityCounter is available during recovery" do
      # The counter process must be registered — this was the original bug
      pid = Process.whereis(Minted.Reserves.LiabilityCounter)
      assert pid != nil
      assert Process.alive?(pid)
    end

    test "FeeCounter is available during recovery" do
      pid = Process.whereis(Minted.Reserves.FeeCounter)
      assert pid != nil
      assert Process.alive?(pid)
    end

    test "counters are accessible via Liability tracker after recovery" do
      state = Minted.Reserves.Trackers.Liability.current()
      assert is_integer(state.minted)
      assert is_integer(state.burned)
      assert is_integer(state.outstanding)
    end
  end

  describe "supervision ordering" do
    test "Runner is a child of Storage.Supervisor" do
      children =
        Supervisor.which_children(Minted.Storage.Supervisor)
        |> Enum.map(fn {id, _pid, _type, _modules} -> id end)

      assert Minted.Storage.Runner in children
    end

    test "LiabilityCounter starts before Runner" do
      children =
        Supervisor.which_children(Minted.Storage.Supervisor)
        |> Enum.map(fn {id, _pid, _type, _modules} -> id end)

      counter_idx = Enum.find_index(children, &(&1 == Minted.Reserves.LiabilityCounter))
      runner_idx = Enum.find_index(children, &(&1 == Minted.Storage.Runner))

      # In rest_for_one, children are listed in reverse start order
      # So earlier-started children have higher indices
      assert counter_idx > runner_idx
    end

    test "FeeCounter starts before Runner" do
      children =
        Supervisor.which_children(Minted.Storage.Supervisor)
        |> Enum.map(fn {id, _pid, _type, _modules} -> id end)

      counter_idx = Enum.find_index(children, &(&1 == Minted.Reserves.FeeCounter))
      runner_idx = Enum.find_index(children, &(&1 == Minted.Storage.Runner))

      assert counter_idx > runner_idx
    end

    test "Mint.Supervisor is listed after Storage.Supervisor under Minted.Supervisor" do
      # The whole H2 fix rests on this: under the top supervisor's
      # rest_for_one strategy, Mint.Supervisor (which boots Mint.Spent
      # and its blocked-hashes reader) is not started until
      # Storage.Supervisor.start_link has returned. Storage.Supervisor
      # itself blocks on Runner, and Runner now runs recovery
      # synchronously — so Mint.Spent cannot see a missing / stale
      # blocked_hashes file.
      children =
        Supervisor.which_children(Minted.Supervisor)
        |> Enum.map(fn {id, _pid, _type, _modules} -> id end)

      storage_idx = Enum.find_index(children, &(&1 == Minted.Storage.Supervisor))
      mint_idx = Enum.find_index(children, &(&1 == Minted.Mint.Supervisor))

      assert storage_idx != nil, "Storage.Supervisor must be a child of Minted.Supervisor"
      assert mint_idx != nil, "Mint.Supervisor must be a child of Minted.Supervisor"

      # rest_for_one lists children in reverse start order, so
      # Storage (started first) sits at a higher index than Mint.
      assert storage_idx > mint_idx,
             "Storage.Supervisor must start before Mint.Supervisor so recovery runs before Spent boots"
    end

    test "Mint.Spent booted with the blocked-hashes state Runner produced" do
      # After Runner.init/1 returns, either the blocked-hashes file
      # has been written to disk OR the fallback app env has been set
      # (best-effort persist path in Recovery). By the time Spent
      # boots, one of the two is in place — otherwise Spent's boot
      # scan would silently miss the paid-out tokens the previous
      # crash left behind. This test asserts Spent is alive AND
      # Runner has recorded a completed recovery, which together
      # gate the ordering fix.
      assert Process.alive?(Process.whereis(Minted.Storage.Runner))
      assert Process.alive?(Process.whereis(Minted.Mint.Spent))

      assert :sys.get_state(Minted.Storage.Runner).recovery == :ok
    end
  end
end
