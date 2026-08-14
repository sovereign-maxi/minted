defmodule Minted.Telemetry.Health.System do
  @moduledoc """
  Aggregates component health into an overall system status.

  Statuses: `:healthy` → `:degraded` → `:critical` → `:halted`

  Evaluates periodically and publishes status changes to `telemetry:health`.
  """

  use GenServer

  require Logger

  alias Minted.Events.EventBus
  alias Minted.Events.Telemetry, as: TelemetryEvents
  alias Minted.Operator.Audit
  alias Minted.Storage.Facade, as: StorageFacade
  alias Minted.Telemetry.Alerts.Manager

  @table Minted.Telemetry.Health.System
  # Auto-halt on these alerts. disk_usage_critical prevents data
  # corruption; liability_invariant means burned > minted (accounting
  # corruption — continuing compounds it); reserve_deficit means
  # held < outstanding (continuing to mint deepens insolvency).
  @halt_alerts MapSet.new([:disk_usage_critical, :liability_invariant, :reserve_deficit])

  # --- Public API ---

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @type status :: :healthy | :degraded | :critical | :halted

  @doc "Returns the current overall system status."
  @spec status() :: status()
  def status do
    case :persistent_term.get({__MODULE__, :halted}, nil) do
      {true, _} ->
        :halted

      _ ->
        case :ets.lookup(@table, :status) do
          [{:status, s}] -> s
          [] -> :healthy
        end
    end
  rescue
    ArgumentError -> :healthy
  end

  @doc "Returns per-component health status."
  @spec components() :: %{atom() => status()}
  def components do
    case :ets.lookup(@table, :components) do
      [{:components, c}] -> c
      [] -> default_components()
    end
  rescue
    ArgumentError -> default_components()
  end

  @doc "Explicitly sets the system to halted status with a reason."
  @spec set_halted(String.t()) :: :ok
  def set_halted(reason) do
    now = DateTime.utc_now()
    Logger.error("System: system halted — #{reason}")
    :persistent_term.put({__MODULE__, :halted}, {true, reason})
    persist_halt_state(reason)
    Audit.record(:halt_set, %{reason: reason, at: now})

    try do
      GenServer.call(__MODULE__, {:set_halted, reason}, 5_000)
    catch
      :exit, _ ->
        Logger.error("System: GenServer unreachable, halt via persistent_term")
        :ok
    end
  end

  @doc "Clears a previously set halt for operator recovery."
  @spec clear_halt() :: :ok
  def clear_halt do
    now = DateTime.utc_now()
    Logger.warning("System: halt cleared by operator")
    :persistent_term.erase({__MODULE__, :halted})
    clear_halt_state_file()
    Audit.record(:halt_cleared, %{at: now})

    try do
      GenServer.call(__MODULE__, :clear_halt, 5_000)
    catch
      :exit, _ -> :ok
    end
  end

  # The halt flag must survive a restart even when the audit-log
  # append fails (a full disk is exactly when the disk-usage halt
  # fires). This small fsynced file is the durability anchor; the
  # audit log stays the forensic record.
  defp persist_halt_state(reason) do
    path = StorageFacade.halt_state_path()
    File.mkdir_p!(Path.dirname(path))

    case File.write(path, reason, [:sync]) do
      :ok ->
        File.chmod(path, 0o600)

      {:error, err} ->
        Logger.error("System: failed to persist halt state, reason=#{inspect(err)}")
    end
  rescue
    e -> Logger.error("System: failed to persist halt state, reason=#{inspect(e)}")
  end

  defp clear_halt_state_file do
    File.rm(StorageFacade.halt_state_path())
    :ok
  end

  @doc "Returns full health report."
  @spec details() :: %{status: status(), components: map(), active_alerts: [map()]}
  def details do
    %{
      status: status(),
      components: components(),
      active_alerts:
        Manager.active_alerts()
        |> Enum.map(fn rule ->
          %{name: rule.name, severity: rule.severity, reason: rule.reason}
        end)
    }
  end

  # --- GenServer Callbacks ---

  @impl true
  def init(opts) do
    table = :ets.new(@table, [:named_table, :protected, :set])
    interval = Keyword.get(opts, :interval_ms, get_config(:alert_interval_ms, 15_000))

    :ets.insert(table, {:status, :healthy})
    :ets.insert(table, {:components, default_components()})

    schedule_eval(interval)

    {:ok, %{table: table, interval_ms: interval, previous_status: :healthy}}
  end

  @impl true
  def handle_call({:set_halted, reason}, _from, state) do
    :ets.insert(state.table, {:status, :halted})
    :ets.insert(state.table, {:halt_reason, reason})
    publish_status_change(:halted)
    {:reply, :ok, %{state | previous_status: :halted}}
  end

  def handle_call(:clear_halt, _from, state) do
    :ets.insert(state.table, {:status, :healthy})
    :ets.delete(state.table, :halt_reason)
    publish_status_change(:healthy)
    {:reply, :ok, %{state | previous_status: :healthy}}
  end

  @impl true
  def handle_info(:evaluate, state) do
    alerts = Manager.active_alerts()
    computed_status = derive_status(alerts)
    component_map = derive_components(alerts)

    # Halt-class alerts must ENGAGE the guard, not just the dashboard:
    # the persistent_term flag is what Guards.ensure_operational!/0 and
    # the controller plug read. Writing only the ETS status here left
    # the mint signing and paying through reserve_deficit /
    # liability_invariant / disk_usage_critical.
    maybe_engage_halt(alerts, computed_status)

    # A halt (operator or auto) is LATCHED until clear_halt/0: never
    # recompute the reported status back to :healthy while the guard
    # flag is set, or dashboards would announce recovery mid-incident.
    new_status =
      case :persistent_term.get({__MODULE__, :halted}, nil) do
        {true, _} -> :halted
        _ -> computed_status
      end

    :ets.insert(state.table, {:status, new_status})
    :ets.insert(state.table, {:components, component_map})

    state =
      if new_status != state.previous_status do
        log_transition(state.previous_status, new_status)
        publish_status_change(new_status)
        %{state | previous_status: new_status}
      else
        state
      end

    schedule_eval(state.interval_ms)
    {:noreply, state}
  end

  # Writes the same persistent_term flag that the operator-facing
  # set_halted/1 writes, minus the GenServer.call (we ARE the
  # GenServer — a call to self would time out). Idempotent: an alert
  # that keeps firing does not stack audit entries. Gated on
  # :auto_halt_enabled so test suites can drive the loop deterministically.
  defp maybe_engage_halt(alerts, :halted) do
    if get_config(:auto_halt_enabled, true) do
      case :persistent_term.get({__MODULE__, :halted}, nil) do
        {true, _} -> :ok
        _ -> engage_auto_halt(alerts)
      end
    end
  end

  defp maybe_engage_halt(_alerts, _status), do: :ok

  defp engage_auto_halt(alerts) do
    names =
      alerts
      |> Enum.filter(&MapSet.member?(@halt_alerts, &1.name))
      |> Enum.map(& &1.name)

    reason = "auto-halt on halt-class alert(s): #{Enum.join(names, ", ")}"
    Logger.error("System: #{reason}")
    :persistent_term.put({__MODULE__, :halted}, {true, reason})
    persist_halt_state(reason)
    Audit.record(:halt_set, %{reason: reason, at: DateTime.utc_now()})
    :ok
  end

  # --- Private ---

  defp derive_status(alerts) do
    cond do
      Enum.any?(alerts, fn r -> MapSet.member?(@halt_alerts, r.name) end) ->
        :halted

      Enum.any?(alerts, fn r -> r.severity in [:critical, :emergency] end) ->
        :critical

      Enum.any?(alerts, fn r -> r.severity == :warning end) ->
        :degraded

      true ->
        :healthy
    end
  end

  defp derive_components(alerts) do
    %{
      lightning:
        component_status(alerts, [
          :lightning_unreachable,
          :liquidity_critical,
          :liquidity_low,
          :melt_settlement_stuck,
          :payment_exhausted
        ]),
      reserves: component_status(alerts, [:reserve_deficit, :liability_invariant, :proof_publication_missed]),
      storage:
        component_status(alerts, [
          :backup_overdue,
          :disk_usage_high,
          :disk_usage_critical,
          :dets_near_limit,
          :spent_set_memory_high,
          :keyset_rotation_due
        ]),
      identity: component_status(alerts, [:rate_limit_surge, :double_spend_rate_high]),
      system: component_status(alerts, [:cpu_high, :cpu_critical, :memory_high, :memory_critical]),
      tor: component_status(alerts, [:tor_unreachable, :tor_degraded])
    }
  end

  defp component_status(alerts, relevant_names) do
    active = Enum.filter(alerts, &(&1.name in relevant_names))

    cond do
      active == [] -> :healthy
      Enum.any?(active, &(&1.severity == :emergency)) -> :halted
      Enum.any?(active, &(&1.severity == :critical)) -> :critical
      Enum.any?(active, &(&1.severity == :warning)) -> :degraded
      true -> :healthy
    end
  end

  defp log_transition(prev, current) do
    Logger.warning("System: health changed: #{prev} → #{current}")
  end

  defp publish_status_change(status) do
    EventBus.publish(%TelemetryEvents.SystemStatusChanged{
      status: status,
      timestamp: DateTime.utc_now()
    })
  end

  defp schedule_eval(interval) do
    Process.send_after(self(), :evaluate, interval)
  end

  defp default_components do
    %{
      lightning: :healthy,
      reserves: :healthy,
      storage: :healthy,
      identity: :healthy,
      system: :healthy,
      tor: :healthy
    }
  end

  defp get_config(key, default) do
    Application.get_env(:minted, :telemetry, [])
    |> Keyword.get(key, default)
  end
end
