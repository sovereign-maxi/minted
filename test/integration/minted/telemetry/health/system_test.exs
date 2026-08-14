# Integration test
defmodule Minted.Telemetry.Health.SystemIntegrationTest do
  @moduledoc "Integration tests for halt-class alert auto-engagement in Minted.Telemetry.Health.System."

  use Minted.IntegrationCase

  alias Minted.Guards
  alias Minted.Telemetry.Alerts.Manager
  alias Minted.Telemetry.Health.System

  test "firing halt-class alert engages the guard until the operator clears it" do
    # Production defaults this to true; test env disables it so organic
    # alert states can't halt the suite. Enable it for this test.
    telemetry_cfg = Application.get_env(:minted, :telemetry, [])
    Application.put_env(:minted, :telemetry, Keyword.put(telemetry_cfg, :auto_halt_enabled, true))
    on_exit(fn -> Application.put_env(:minted, :telemetry, telemetry_cfg) end)
    on_exit(fn -> System.clear_halt() end)

    # Drive the real :liability_invariant rule into firing: burned > minted.
    Locker.Counter.increment(Minted.Reserves.LiabilityCounter, :total_burned, 1)

    send(GenServer.whereis(Manager), :evaluate)
    _ = :sys.get_state(Manager)
    assert Enum.any?(Manager.active_alerts(), &(&1.name == :liability_invariant))

    # The health evaluation must ENGAGE the guard flag, not just the
    # dashboard status.
    send(GenServer.whereis(System), :evaluate)
    _ = :sys.get_state(System)

    refute Guards.operational?()
    assert System.status() == :halted

    # The halt is latched. Resolve the condition, push the rule
    # through its resolve_after window, re-evaluate — still halted.
    Locker.Counter.reset(Minted.Reserves.LiabilityCounter)

    for _ <- 1..3 do
      send(GenServer.whereis(Manager), :evaluate)
      _ = :sys.get_state(Manager)
    end

    refute Enum.any?(Manager.active_alerts(), &(&1.name == :liability_invariant))

    send(GenServer.whereis(System), :evaluate)
    _ = :sys.get_state(System)

    refute Guards.operational?()
    assert System.status() == :halted

    System.clear_halt()
    assert Guards.operational?()
  end
end
