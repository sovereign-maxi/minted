defmodule Minted.Lightning.ETSHolderIntegrationTest do
  @moduledoc """
  Verifies that the Lightning ETS tables are owned by the long-lived
  ETSHolder rather than any transient caller process. The tables MUST
  survive the death of any process that reads or writes them —
  otherwise a Phoenix connection process that first creates the table
  destroys it on exit and every in-flight melt loses its
  payment-id-to-hash mapping mid-flight.
  """

  use Minted.IntegrationCase

  @tables [
    Minted.Lightning.Executor.IdMap,
    Minted.Lightning.Executor.InFlight,
    FireBird.Webhook,
    FireBird.Webhook.RateLimit
  ]

  describe "table ownership" do
    test "all Lightning ETS tables exist at boot" do
      for table <- @tables do
        assert :ets.whereis(table) != :undefined,
               "expected #{inspect(table)} to exist as an ETS table"
      end
    end

    test "tables are owned by the ETSHolder GenServer" do
      holder_pid = Process.whereis(Minted.Lightning.ETSHolder)
      assert is_pid(holder_pid), "ETSHolder must be running"

      for table <- @tables do
        owner = :ets.info(table, :owner)

        assert owner == holder_pid,
               "#{inspect(table)} should be owned by ETSHolder (#{inspect(holder_pid)}), got #{inspect(owner)}"
      end
    end

    test "tables survive the death of a transient writer process" do
      table = Minted.Lightning.Executor.IdMap

      transient =
        spawn(fn ->
          :ets.insert(table, {"transient-key", "value"})
        end)

      ref = Process.monitor(transient)
      assert_receive {:DOWN, ^ref, :process, ^transient, _}, 1_000

      # After the writer exits, the table + entry must still be there
      # because the holder owns it, not the transient process.
      assert :ets.whereis(table) != :undefined
      assert :ets.lookup(table, "transient-key") == [{"transient-key", "value"}]

      # Clean up.
      :ets.delete(table, "transient-key")
    end
  end

  describe "in-flight counter seeding" do
    setup do
      # Reset so we observe what the seed left, not what a prior test
      # incremented.
      table = Minted.Lightning.Executor.InFlight
      :ets.delete_all_objects(table)
      :ok
    end

    test "counters survive delete_all_objects via update_counter default" do
      table = Minted.Lightning.Executor.InFlight

      # After a wipe, the counter keys are missing. `update_counter/4`'s
      # default form seeds a fresh {key, 0} and then applies the
      # increment — the executor's `acquire_flight_slot` relies on this
      # exact behaviour to recover from a between-test wipe.
      assert :ets.lookup(table, :count_in_flight) == []

      new_count = :ets.update_counter(table, :count_in_flight, {2, 1}, {:count_in_flight, 0})
      assert new_count == 1
    end
  end
end
