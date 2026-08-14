defmodule Minted.Telemetry.Alerts.ManagerIntegrationTest do
  @moduledoc "Integration tests for alert manager rule evaluation and alert lifecycle."

  use Minted.IntegrationCase

  alias Minted.Telemetry.Alerts.Manager

  test "a rule condition that exits cannot kill the manager" do
    pid = GenServer.whereis(Manager)

    # This rule's condition EXITS (GenServer.call to a dead name)
    # rather than raising. The pre-fix Task.async linked the task to
    # the Manager, so the exit propagated and killed the whole alert
    # pipeline once per eval tick.
    :ok =
      Manager.__insert_rule__(%Minted.Telemetry.Alerts.Rule{
        name: :__exit_test__,
        domain: :system,
        condition: fn -> GenServer.call(:no_such_process_xyz, :ping) end,
        severity: :warning
      })

    on_exit(fn -> Manager.__delete_rule__(:__exit_test__) end)

    send(pid, :evaluate)
    _ = :sys.get_state(pid)

    assert Process.alive?(pid)
    assert Enum.any?(Manager.all_rules(), &(&1.name == :__exit_test__))
  end

  test "active_alerts/0 returns a list" do
    alerts = Manager.active_alerts()
    assert is_list(alerts)
  end

  test "all_rules/0 returns all default rules" do
    rules = Manager.all_rules()
    assert length(rules) == 27
  end

  test "all rules have required fields" do
    Enum.each(Manager.all_rules(), fn rule ->
      assert is_atom(rule.name)
      assert rule.severity in [:info, :warning, :critical, :emergency]
      assert is_function(rule.condition, 0)
    end)
  end

  test "naming convention: every _high rule has a _critical sibling" do
    # Any threshold-paired rule named `*_high` (or `*_low` for inverted
    # metrics like liquidity) must have a matching `*_critical`. This
    # is the rule that keeps the alert taxonomy consistent: severity
    # suffixes only appear when a paired tier exists.
    names = Manager.all_rules() |> Enum.map(& &1.name) |> MapSet.new()

    paired_warning_suffixes = ["_high", "_low"]

    orphans =
      names
      |> Enum.filter(fn name ->
        str = Atom.to_string(name)

        Enum.any?(paired_warning_suffixes, fn suffix ->
          String.ends_with?(str, suffix) and
            not MapSet.member?(
              names,
              String.replace_suffix(str, suffix, "_critical") |> String.to_atom()
            )
        end)
      end)

    assert orphans == [],
           "Found _high/_low rules without a _critical sibling: #{inspect(orphans)}. " <>
             "Either add the missing _critical rule or rename to a descriptive single-tier name."
  end

  test "default rules include expected alert names" do
    names = Manager.all_rules() |> Enum.map(& &1.name) |> MapSet.new()

    expected = [
      :reserve_deficit,
      :liquidity_critical,
      :liquidity_low,
      :lightning_unreachable,
      :double_spend_rate_high,
      :proof_publication_missed,
      :payment_exhausted,
      :backup_overdue,
      :disk_usage_high,
      :rate_limit_surge,
      :pending_signatures_high,
      :pending_signatures_critical,
      :orphan_deposits_reconciled,
      :double_spend_rate_critical,
      :spent_set_memory_critical
    ]

    Enum.each(expected, fn name ->
      assert MapSet.member?(names, name), "Expected alert rule #{name} not found"
    end)
  end

  test "rule evaluation timeout does not block the GenServer" do
    # Set a short timeout for this test.
    prev_telemetry = Application.get_env(:minted, :telemetry, [])

    Application.put_env(
      :minted,
      :telemetry,
      Keyword.put(prev_telemetry, :alert_eval_timeout_ms, 200)
    )

    on_exit(fn -> Application.put_env(:minted, :telemetry, prev_telemetry) end)

    # Insert a hanging rule via the GenServer process (ETS is :protected)
    hanging_rule = %Minted.Telemetry.Alerts.Rule{
      name: :test_hang,
      domain: "Test",
      severity: :warning,
      for_duration: 0,
      condition: fn -> Process.sleep(:infinity) end
    }

    :sys.replace_state(Manager, fn state ->
      :ets.insert(state.table, {:test_hang, hanging_rule})
      state
    end)

    # Trigger evaluation — should complete within timeout (200ms), not hang forever.
    send(Manager, :evaluate)

    # Synchronize: :sys.get_state blocks until the GenServer processes all prior messages,
    # including the :evaluate we just sent (which includes the 200ms per-rule timeout).
    :sys.get_state(Manager)

    # If the GenServer is not permanently blocked, all_rules still works.
    rules = Manager.all_rules()
    assert is_list(rules)

    # The hanging rule should still be in its original state (not transitioned)
    case Enum.find(rules, &(&1.name == :test_hang)) do
      nil -> :ok
      rule -> assert rule.state == :ok
    end

    # Clean up via GenServer process.
    :sys.replace_state(Manager, fn state ->
      :ets.delete(state.table, :test_hang)
      state
    end)
  end

  test "safety rules do not fire on a healthy system" do
    # These rules should not fire in a clean test run.
    safety_rules = [
      :double_spend_rate_high,
      :disk_usage_high,
      :rate_limit_surge
    ]

    firing_names = Manager.active_alerts() |> Enum.map(& &1.name) |> MapSet.new()

    Enum.each(safety_rules, fn name ->
      refute MapSet.member?(firing_names, name),
             "rule #{name} should not be firing on a healthy single-node"
    end)
  end
end
