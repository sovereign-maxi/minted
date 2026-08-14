defmodule Minted.Telemetry.Health.SystemTest do
  @moduledoc "Unit tests for Minted.Telemetry.Health.System."

  use ExUnit.Case, async: false

  alias Minted.Telemetry.Health.System

  test "status/0 returns an atom" do
    status = System.status()
    assert status in [:healthy, :degraded, :critical, :halted]
  end

  test "components/0 returns a map with all 6 components" do
    components = System.components()
    assert is_map(components)

    expected_keys = [:lightning, :reserves, :storage, :identity, :system, :tor]

    Enum.each(expected_keys, fn key ->
      assert Map.has_key?(components, key), "Missing component: #{key}"
      assert components[key] in [:healthy, :degraded, :critical, :halted]
    end)
  end

  test "details/0 returns a full health report" do
    details = System.details()

    assert Map.has_key?(details, :status)
    assert Map.has_key?(details, :components)
    assert Map.has_key?(details, :active_alerts)

    assert details.status in [:healthy, :degraded, :critical, :halted]
    assert is_map(details.components)
    assert is_list(details.active_alerts)
  end

  test "status/0 returns a valid status atom" do
    # Status may not be :healthy if alert conditions fire during test.
    assert System.status() in [:healthy, :degraded, :critical, :halted]
  end

  test "components/0 values are all valid status atoms" do
    components = System.components()

    Enum.each(components, fn {_component, status} ->
      assert status in [:healthy, :degraded, :critical, :halted]
    end)
  end
end
