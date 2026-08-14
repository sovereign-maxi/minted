defmodule Minted.Telemetry.Alerts.RuleTest do
  @moduledoc "Unit tests for Minted.Telemetry.Alerts.Rule."

  use ExUnit.Case, async: true

  alias Minted.Telemetry.Alerts.Rule

  defp make_rule(opts \\ []) do
    %Rule{
      name: Keyword.get(opts, :name, :test_alert),
      domain: Keyword.get(opts, :domain, "Test"),
      severity: Keyword.get(opts, :severity, :warning),
      condition: Keyword.get(opts, :condition, fn -> :ok end),
      for_duration: Keyword.get(opts, :for_duration, 0),
      resolve_after: Keyword.get(opts, :resolve_after, 0)
    }
  end

  test "new rule starts in :ok state" do
    rule = make_rule()
    assert rule.state == :ok
    refute Rule.firing?(rule)
  end

  test "immediate alert (for_duration=0) transitions ok -> firing" do
    rule = make_rule(condition: fn -> {:alert, "test problem"} end)
    evaluated = Rule.evaluate(rule)

    assert evaluated.state == :firing
    assert evaluated.reason == "test problem"
    assert evaluated.fired_at != nil
    assert Rule.firing?(evaluated)
  end

  test "debounced alert transitions ok -> pending -> firing" do
    rule =
      make_rule(
        condition: fn -> {:alert, "slow issue"} end,
        for_duration: 10
      )

    pending = Rule.evaluate(rule)
    assert pending.state == :pending
    assert pending.reason == "slow issue"
    refute Rule.firing?(pending)

    # Backdate pending_since to simulate time passing beyond for_duration.
    expired = %{pending | pending_since: System.monotonic_time(:millisecond) - 20}

    fired = Rule.evaluate(expired)
    assert fired.state == :firing
    assert Rule.firing?(fired)
  end

  test "firing -> resolving -> resolved when condition clears" do
    rule = make_rule(condition: fn -> {:alert, "issue"} end, resolve_after: 3)
    fired = Rule.evaluate(rule)
    assert fired.state == :firing

    cleared = %{fired | condition: fn -> :ok end}
    r1 = Rule.evaluate(cleared)
    assert r1.state == :resolving

    r2 = Rule.evaluate(r1)
    assert r2.state == :resolving

    r3 = Rule.evaluate(r2)
    assert r3.state == :resolved
    assert r3.resolved_at != nil
    refute Rule.firing?(r3)
  end

  test "firing -> resolved immediately when resolve_after is 0" do
    rule = make_rule(condition: fn -> {:alert, "issue"} end, resolve_after: 0)
    fired = Rule.evaluate(rule)
    assert fired.state == :firing

    cleared = %{fired | condition: fn -> :ok end}
    resolved = Rule.evaluate(cleared)
    assert resolved.state == :resolved
  end

  test "resolved -> ok on next clear evaluation" do
    rule = make_rule(condition: fn -> {:alert, "issue"} end, resolve_after: 0)
    fired = Rule.evaluate(rule)
    cleared = %{fired | condition: fn -> :ok end}
    resolved = Rule.evaluate(cleared)
    assert resolved.state == :resolved

    back_to_ok = Rule.evaluate(resolved)
    assert back_to_ok.state == :ok
  end

  test "resolving -> firing if condition re-alerts" do
    rule = make_rule(condition: fn -> {:alert, "issue"} end, resolve_after: 3)
    fired = Rule.evaluate(rule)

    cleared = %{fired | condition: fn -> :ok end}
    resolving = Rule.evaluate(cleared)
    assert resolving.state == :resolving

    re_alert = %{resolving | condition: fn -> {:alert, "back again"} end}
    re_fired = Rule.evaluate(re_alert)
    assert re_fired.state == :firing
    assert re_fired.reason == "back again"
  end

  test "resolved -> firing if condition re-alerts" do
    rule = make_rule(condition: fn -> {:alert, "issue"} end, resolve_after: 0)
    fired = Rule.evaluate(rule)

    cleared = %{fired | condition: fn -> :ok end}
    resolved = Rule.evaluate(cleared)
    assert resolved.state == :resolved

    re_alert = %{resolved | condition: fn -> {:alert, "back again"} end}
    re_fired = Rule.evaluate(re_alert)
    assert re_fired.state == :firing
    assert re_fired.reason == "back again"
  end

  test "pending -> ok if condition clears before for_duration" do
    rule =
      make_rule(
        condition: fn -> {:alert, "flap"} end,
        for_duration: 60_000
      )

    pending = Rule.evaluate(rule)
    assert pending.state == :pending

    cleared = %{pending | condition: fn -> :ok end}
    ok = Rule.evaluate(cleared)
    assert ok.state == :ok
  end

  test "firing? returns true only for firing state" do
    assert Rule.firing?(%Rule{
             name: :t,
             domain: "Test",
             severity: :warning,
             condition: fn -> :ok end,
             state: :firing
           })

    refute Rule.firing?(%Rule{
             name: :t,
             domain: "Test",
             severity: :warning,
             condition: fn -> :ok end,
             state: :ok
           })

    refute Rule.firing?(%Rule{
             name: :t,
             domain: "Test",
             severity: :warning,
             condition: fn -> :ok end,
             state: :pending
           })

    refute Rule.firing?(%Rule{
             name: :t,
             domain: "Test",
             severity: :warning,
             condition: fn -> :ok end,
             state: :resolved
           })
  end

  test "condition exception is treated as :ok" do
    rule = make_rule(condition: fn -> raise "boom" end)
    result = Rule.evaluate(rule)
    assert result.state == :ok
  end
end
