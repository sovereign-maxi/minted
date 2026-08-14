defmodule Minted.Identity.EscalationIntegrationTest do
  @moduledoc "Integration tests for identity escalation and rate limiter multiplier logic."

  use Minted.IntegrationCase

  import Minted.TestHelpers.ProcessHelpers

  alias Minted.Identity.Escalation

  setup do
    # Ensure RateLimiter is running (escalation writes multipliers there).
    case GenServer.whereis(Seer.RateLimiter) do
      nil ->
        {:ok, rl_pid} =
          Seer.RateLimiter.start_link(
            limits: %{deposit: {10, 300}, withdraw: {5, 300}, swap: {20, 300}, info: {100, 60}},
            global_multiplier: 10
          )

        on_exit(fn -> safe_stop(rl_pid) end)

      _pid ->
        :ok
    end

    # Start the Escalation GenServer if not running.
    # Its init/1 creates the ETS table and subscribes to events.
    case GenServer.whereis(Escalation) do
      nil ->
        {:ok, pid} = Escalation.start_link()
        on_exit(fn -> safe_stop(pid) end)
        :ok

      _pid ->
        :ets.delete_all_objects(Minted.Identity.Escalation)
        :ok
    end
  end

  defp unique_circuit do
    :crypto.hash(:sha256, "circuit_#{:erlang.unique_integer([:positive, :monotonic])}")
  end

  describe "record/1 and status/1" do
    test "first record escalates to base multiplier (3x)" do
      circuit = unique_circuit()

      assert :ok == Escalation.status(circuit)

      :ok = Escalation.record(circuit)

      assert {:escalated, 3} = Escalation.status(circuit)
    end

    test "second record escalates to 9x" do
      circuit = unique_circuit()

      :ok = Escalation.record(circuit)
      :ok = Escalation.record(circuit)

      assert {:escalated, 9} = Escalation.status(circuit)
    end

    test "third record escalates to 27x" do
      circuit = unique_circuit()

      :ok = Escalation.record(circuit)
      :ok = Escalation.record(circuit)
      :ok = Escalation.record(circuit)

      assert {:escalated, 27} = Escalation.status(circuit)
    end

    test "fourth record escalates to max 81x" do
      circuit = unique_circuit()

      for _ <- 1..4, do: Escalation.record(circuit)

      assert {:escalated, 81} = Escalation.status(circuit)
    end

    test "multiplier is capped at 81x even with more records" do
      circuit = unique_circuit()

      for _ <- 1..10, do: Escalation.record(circuit)

      assert {:escalated, 81} = Escalation.status(circuit)
    end
  end

  describe "banned?/1" do
    test "not banned initially" do
      circuit = unique_circuit()
      refute Escalation.banned?(circuit)
    end

    test "banned after reaching max multiplier" do
      circuit = unique_circuit()

      for _ <- 1..4, do: Escalation.record(circuit)

      assert Escalation.banned?(circuit)
    end

    test "not banned at lower escalation levels" do
      circuit = unique_circuit()

      Escalation.record(circuit)
      refute Escalation.banned?(circuit)

      Escalation.record(circuit)
      refute Escalation.banned?(circuit)

      Escalation.record(circuit)
      refute Escalation.banned?(circuit)
    end
  end

  describe "reset/1" do
    test "clears escalation state for a circuit" do
      circuit = unique_circuit()

      for _ <- 1..3, do: Escalation.record(circuit)
      assert {:escalated, 27} = Escalation.status(circuit)

      :ok = Escalation.reset(circuit)
      assert :ok == Escalation.status(circuit)
    end

    test "resetting one circuit does not affect others" do
      c1 = unique_circuit()
      c2 = unique_circuit()

      Escalation.record(c1)
      Escalation.record(c2)

      :ok = Escalation.reset(c1)

      assert :ok == Escalation.status(c1)
      assert {:escalated, 3} = Escalation.status(c2)
    end
  end

  describe "cooldown behavior" do
    test "escalation expires after cooldown period" do
      circuit = unique_circuit()

      Escalation.record(circuit)
      assert {:escalated, 3} = Escalation.status(circuit)

      # Manually expire the entry by writing directly to ETS with a past timestamp.
      past_mono = System.monotonic_time(:second) - 1

      [{^circuit, count, mult, _expires}] =
        :ets.lookup(Minted.Identity.Escalation, circuit)

      :ets.insert(Minted.Identity.Escalation, {circuit, count, mult, past_mono})

      # Should now appear as not escalated
      assert :ok == Escalation.status(circuit)
    end

    test "new record after cooldown resets count to 1" do
      circuit = unique_circuit()

      # Record twice (9x)
      Escalation.record(circuit)
      Escalation.record(circuit)
      assert {:escalated, 9} = Escalation.status(circuit)

      # Expire the entry manually
      past_mono = System.monotonic_time(:second) - 1

      [{^circuit, count, mult, _expires}] =
        :ets.lookup(Minted.Identity.Escalation, circuit)

      :ets.insert(Minted.Identity.Escalation, {circuit, count, mult, past_mono})

      # New record should start fresh at count=1 (3x)
      Escalation.record(circuit)
      assert {:escalated, 3} = Escalation.status(circuit)
    end

    test "record within cooldown window stacks multiplier" do
      circuit = unique_circuit()

      Escalation.record(circuit)
      assert {:escalated, 3} = Escalation.status(circuit)

      # Record again immediately (within cooldown)
      Escalation.record(circuit)
      assert {:escalated, 9} = Escalation.status(circuit)
    end
  end

  describe "cleanup/0" do
    test "removes expired entries" do
      circuit = unique_circuit()

      Escalation.record(circuit)
      assert {:escalated, 3} = Escalation.status(circuit)

      # Expire the entry
      past_mono = System.monotonic_time(:second) - 1

      [{^circuit, count, mult, _expires}] =
        :ets.lookup(Minted.Identity.Escalation, circuit)

      :ets.insert(Minted.Identity.Escalation, {circuit, count, mult, past_mono})

      :ok = Escalation.cleanup()

      # Entry should be fully removed from ETS
      assert [] = :ets.lookup(Minted.Identity.Escalation, circuit)
    end

    test "does not remove active entries" do
      circuit = unique_circuit()

      Escalation.record(circuit)

      :ok = Escalation.cleanup()

      # Should still be escalated
      assert {:escalated, 3} = Escalation.status(circuit)
    end
  end

  describe "independent circuits" do
    test "escalation state is per-circuit" do
      c1 = unique_circuit()
      c2 = unique_circuit()
      c3 = unique_circuit()

      Escalation.record(c1)
      Escalation.record(c2)
      Escalation.record(c2)

      assert {:escalated, 3} = Escalation.status(c1)
      assert {:escalated, 9} = Escalation.status(c2)
      assert :ok == Escalation.status(c3)
    end
  end
end
