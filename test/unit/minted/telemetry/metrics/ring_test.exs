defmodule Minted.Telemetry.Metrics.RingTest do
  @moduledoc "Unit tests for Minted.Telemetry.Metrics.Ring."

  use ExUnit.Case, async: false

  alias Minted.Telemetry.Metrics.Ring

  # The Ring GenServer is started by the application supervisor.
  # Tests use the running instance.

  test "latest returns a snapshot" do
    snapshot = Ring.latest()
    assert is_map(snapshot)
    assert Map.has_key?(snapshot, :cpu_pct)
    assert Map.has_key?(snapshot, :memory_pct)
    assert Map.has_key?(snapshot, :disks)
    assert Map.has_key?(snapshot, :beam_memory_mb)
    assert Map.has_key?(snapshot, :beam_processes)
    assert Map.has_key?(snapshot, :uptime_hours)
  end

  test "series returns data points for a key" do
    series = Ring.series(:cpu_pct, 10)
    assert is_list(series)
    assert series != []

    [{ts, val} | _] = series
    assert is_integer(ts)
    assert is_number(val)
  end

  test "series returns entries with zero for unknown keys" do
    series = Ring.series(:nonexistent_key, 10)
    assert is_list(series)
    assert series != []
    assert Enum.all?(series, fn {_ts, val} -> val == 0 end)
  end
end
