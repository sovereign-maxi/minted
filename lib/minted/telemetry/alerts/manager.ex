defmodule Minted.Telemetry.Alerts.Manager do
  @moduledoc """
  Periodically evaluates alert rules and publishes state transitions
  to the EventBus. Ships with 15 default rules covering all contexts.
  """

  use GenServer

  # Peer health check is guarded at runtime — may not be available during bootstrap.
  @dialyzer []

  require Logger

  alias Minted.Events.EventBus
  alias Minted.Events.Telemetry, as: TelemetryEvents
  alias Minted.Mint.Facade, as: MintFacade
  alias Minted.Storage.Facade, as: StorageFacade
  alias Minted.Telemetry.Alerts.Rule
  alias Minted.Telemetry.Health.{Cache, Metrics}

  @table Minted.Telemetry.Alerts.Manager
  @sign_fail_counter Minted.Telemetry.Alerts.Manager.SignFailCounter
  @default_eval_timeout_ms 5_000

  # --- Public API ---

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "Returns all currently firing alerts."
  @spec active_alerts() :: [Rule.t()]
  def active_alerts do
    @table
    |> :ets.tab2list()
    |> Enum.map(fn {_name, rule} -> rule end)
    |> Enum.filter(&Rule.firing?/1)
  rescue
    e ->
      Logger.warning("Manager: active_alerts failed: #{inspect(e)}")
      []
  end

  @doc "Returns all alert rules with their current states."
  @spec all_rules() :: [Rule.t()]
  def all_rules do
    @table
    |> :ets.tab2list()
    |> Enum.map(fn {_name, rule} -> rule end)
  rescue
    e ->
      Logger.warning("Manager: all_rules failed: #{inspect(e)}")
      []
  end

  if Mix.env() == :test do
    @doc false
    # Test-only seam: the rules table is :protected, so integration
    # tests can't inject (or remove) a hostile rule condition from
    # outside the GenServer.
    def __insert_rule__(%Rule{} = rule) do
      GenServer.call(__MODULE__, {:__test_insert_rule__, rule})
    end

    @doc false
    def __delete_rule__(name) when is_atom(name) do
      GenServer.call(__MODULE__, {:__test_delete_rule__, name})
    end
  end

  # --- GenServer Callbacks ---

  @impl true
  def init(opts) do
    table = :ets.new(@table, [:named_table, :protected, :set])
    interval = Keyword.get(opts, :interval_ms, get_config(:alert_interval_ms, 15_000))

    # ETS counter for signing failures.
    :ets.new(@sign_fail_counter, [:named_table, :public, :set])
    :ets.insert(@sign_fail_counter, {:count, 0})

    # Attach telemetry handler for sign_failed events.
    :telemetry.attach(
      "alert-manager-sign-failed",
      [:minted, :mint, :sign_failed],
      &__MODULE__.handle_sign_failed_event/4,
      nil
    )

    rules = default_rules()
    Enum.each(rules, fn rule -> :ets.insert(table, {rule.name, rule}) end)

    schedule_eval(interval)

    {:ok, %{table: table, interval_ms: interval}}
  end

  if Mix.env() == :test do
    @impl true
    def handle_call({:__test_insert_rule__, rule}, _from, state) do
      :ets.insert(state.table, {rule.name, rule})
      {:reply, :ok, state}
    end

    def handle_call({:__test_delete_rule__, name}, _from, state) do
      :ets.delete(state.table, name)
      {:reply, :ok, state}
    end
  end

  @impl true
  def handle_info(:evaluate, state) do
    evaluate_all_rules(state.table)
    schedule_eval(state.interval_ms)
    {:noreply, state}
  end

  @doc false
  def handle_sign_failed_event(_event, _measurements, _metadata, _config) do
    :ets.update_counter(@sign_fail_counter, :count, 1)
  rescue
    _ -> :ok
  end

  # --- Private ---

  defp evaluate_all_rules(table) do
    table
    |> :ets.tab2list()
    |> Enum.each(fn {name, rule} ->
      prev_state = rule.state

      updated =
        try do
          # async_nolink: a rule condition that EXITS (e.g. GenServer.call
          # to a dead counter GenServer) must not kill this Manager
          # through the task link. The linked Task.async crash-looped the
          # whole alert pipeline once per eval tick — silencing every
          # alert during exactly the incidents they exist for.
          task =
            Task.Supervisor.async_nolink(Minted.TaskSupervisor, fn -> Rule.evaluate(rule) end)

          case Task.yield(task, eval_timeout_ms()) || Task.shutdown(task, :brutal_kill) do
            {:ok, result} ->
              result

            {:exit, reason} ->
              Logger.warning("Manager: rule #{name} evaluation exited: #{inspect(reason)}")
              rule

            nil ->
              Logger.warning("Manager: rule #{name} evaluation timed out")
              rule
          end
        rescue
          e ->
            Logger.warning("Manager: rule #{name} evaluation crashed: #{inspect(e)}")
            rule
        end

      :ets.insert(table, {name, updated})
      notify_transition(prev_state, updated)
    end)
  end

  defp notify_transition(prev_state, %{state: :firing} = rule)
       when prev_state not in [:firing, :resolving] do
    Logger.warning("Manager: alert fired: #{rule.name} (#{rule.severity}) — #{rule.reason}")

    EventBus.publish(%TelemetryEvents.AlertFired{
      name: rule.name,
      domain: rule.domain,
      severity: rule.severity,
      reason: rule.reason,
      timestamp: DateTime.utc_now()
    })

    publish_specific_event(rule, :firing)
  end

  # Re-fire: was resolving but condition returned, back to firing
  defp notify_transition(:resolving, %{state: :firing} = rule) do
    Logger.warning("Manager: alert re-fired: #{rule.name} (#{rule.severity}) — #{rule.reason}")

    EventBus.publish(%TelemetryEvents.AlertFired{
      name: rule.name,
      domain: rule.domain,
      severity: rule.severity,
      reason: rule.reason,
      timestamp: DateTime.utc_now()
    })
  end

  defp notify_transition(prev_state, %{state: :resolved} = rule)
       when prev_state in [:firing, :resolving] do
    Logger.info("Manager: alert resolved: #{rule.name}")

    EventBus.publish(%TelemetryEvents.AlertResolved{
      name: rule.name,
      domain: rule.domain,
      detail: rule.reason,
      timestamp: DateTime.utc_now()
    })

    publish_specific_event(rule, :resolved)
  end

  defp notify_transition(_prev, _rule), do: :ok

  # Publish domain-specific events alongside generic AlertFired/Resolved.
  # These exist so user-facing UI (wallet LiveView) can subscribe to a
  # narrow set of events without having to filter AlertFired by name.
  defp publish_specific_event(%{name: :tor_unreachable, reason: reason}, :firing) do
    EventBus.publish(%TelemetryEvents.TorDown{
      reason: reason,
      timestamp: DateTime.utc_now()
    })
  end

  defp publish_specific_event(%{name: :tor_unreachable}, :resolved) do
    EventBus.publish(%TelemetryEvents.TorRecovered{timestamp: DateTime.utc_now()})
  end

  defp publish_specific_event(%{name: :tor_degraded, reason: reason}, :firing) do
    EventBus.publish(%TelemetryEvents.TorDegraded{
      reason: reason,
      timestamp: DateTime.utc_now()
    })
  end

  defp publish_specific_event(%{name: :tor_degraded}, :resolved) do
    EventBus.publish(%TelemetryEvents.TorRecovered{timestamp: DateTime.utc_now()})
  end

  defp publish_specific_event(_rule, _transition), do: :ok

  defp schedule_eval(interval) do
    Process.send_after(self(), :evaluate, interval)
  end

  defp eval_timeout_ms do
    get_config(:alert_eval_timeout_ms, @default_eval_timeout_ms)
  end

  defp get_config(key, default) do
    Application.get_env(:minted, :telemetry, [])
    |> Keyword.get(key, default)
  end

  # --- Default Rules ---
  #
  # Naming convention (apply uniformly to any new rule):
  #
  #   • Threshold metrics with multiple severity tiers use the
  #     `_high` / `_critical` suffix pair (or `_low` / `_critical`
  #     when the metric trips going DOWN, e.g. liquidity).
  #     A `_high` rule MUST have a `_critical` sibling — never solo.
  #
  #   • State events (binary or descriptive conditions) use a
  #     propositional phrase that reads true when the alert fires:
  #     `reserve_deficit`, `tor_unreachable`, `backup_overdue`, etc.
  #     No severity suffix.
  #
  # Severity itself is metadata on the Rule struct, not part of the
  # name. Don't repeat severity in the name except to differentiate
  # paired threshold tiers.

  defp default_rules do
    [
      %Rule{
        name: :reserve_deficit,
        domain: "Reserves",
        severity: :emergency,
        # 60s debounce so a transient mid-melt blip (assets briefly
        # decremented while the matching :tokens_burned commit is
        # still in-flight) doesn't fire and halt the live mint.
        for_duration: 60_000,
        condition: fn -> check_reserve_ratio() end
      },
      %Rule{
        name: :liability_invariant,
        domain: "Reserves",
        severity: :emergency,
        for_duration: 0,
        condition: fn -> check_liability_invariant() end
      },
      %Rule{
        name: :liquidity_critical,
        domain: "Lightning",
        severity: :critical,
        for_duration: 0,
        condition: fn -> check_liquidity(:critical) end
      },
      %Rule{
        name: :liquidity_low,
        domain: "Lightning",
        severity: :warning,
        for_duration: 30_000,
        condition: fn -> check_liquidity(:low) end
      },
      %Rule{
        name: :lightning_unreachable,
        domain: "Lightning",
        severity: :critical,
        for_duration: 15_000,
        resolve_after: 5,
        condition: fn -> check_lightning_reachable() end
      },
      %Rule{
        name: :double_spend_rate_high,
        domain: "Mint",
        severity: :warning,
        for_duration: 60_000,
        condition: fn -> check_double_spend_rate(:high) end
      },
      %Rule{
        name: :double_spend_rate_critical,
        domain: "Mint",
        severity: :critical,
        for_duration: 60_000,
        condition: fn -> check_double_spend_rate(:critical) end
      },
      %Rule{
        name: :proof_publication_missed,
        domain: "Reserves",
        severity: :warning,
        for_duration: 0,
        condition: fn -> check_proof_publication() end
      },
      %Rule{
        name: :payment_exhausted,
        domain: "Lightning",
        severity: :warning,
        for_duration: 0,
        condition: fn -> check_payment_exhausted() end
      },
      %Rule{
        name: :backup_overdue,
        domain: "Mint",
        severity: :warning,
        for_duration: 0,
        condition: fn -> check_backup_overdue() end
      },
      %Rule{
        name: :disk_usage_high,
        domain: "System",
        severity: :warning,
        for_duration: 60_000,
        condition: fn -> check_disk_usage(:high) end
      },
      %Rule{
        name: :disk_usage_critical,
        domain: "System",
        severity: :emergency,
        for_duration: 0,
        condition: fn -> check_disk_usage(:critical) end
      },
      %Rule{
        name: :rate_limit_surge,
        domain: "Mint",
        severity: :info,
        for_duration: 30_000,
        condition: fn -> check_rate_limit_surge() end
      },
      %Rule{
        name: :dets_near_limit,
        domain: "System",
        severity: :warning,
        for_duration: 0,
        condition: fn -> check_dets_file_size() end
      },
      %Rule{
        name: :keyset_rotation_due,
        domain: "Mint",
        severity: :warning,
        for_duration: 0,
        condition: fn -> check_keyset_rotation() end
      },
      %Rule{
        name: :spent_set_memory_high,
        domain: "System",
        severity: :warning,
        for_duration: 60_000,
        condition: fn -> check_spent_set_memory(:high) end
      },
      %Rule{
        name: :spent_set_memory_critical,
        domain: "System",
        severity: :critical,
        for_duration: 60_000,
        condition: fn -> check_spent_set_memory(:critical) end
      },
      %Rule{
        name: :cpu_high,
        domain: "System",
        severity: :warning,
        for_duration: 60_000,
        resolve_after: 3,
        condition: fn -> check_cpu(:high) end
      },
      %Rule{
        name: :cpu_critical,
        domain: "System",
        severity: :critical,
        for_duration: 30_000,
        resolve_after: 3,
        condition: fn -> check_cpu(:critical) end
      },
      %Rule{
        name: :memory_high,
        domain: "System",
        severity: :warning,
        for_duration: 60_000,
        resolve_after: 3,
        condition: fn -> check_memory(:high) end
      },
      %Rule{
        name: :memory_critical,
        domain: "System",
        severity: :critical,
        for_duration: 30_000,
        resolve_after: 3,
        condition: fn -> check_memory(:critical) end
      },
      %Rule{
        name: :melt_settlement_stuck,
        domain: "Mint",
        severity: :critical,
        for_duration: 0,
        condition: fn -> check_melt_settlement_stuck() end
      },
      %Rule{
        name: :tor_unreachable,
        domain: "Tor",
        severity: :critical,
        for_duration: 15_000,
        resolve_after: 3,
        condition: fn -> check_tor_reachable() end
      },
      %Rule{
        name: :tor_degraded,
        domain: "Tor",
        severity: :warning,
        for_duration: 30_000,
        resolve_after: 3,
        condition: fn -> check_tor_degraded() end
      },
      # Pending store growing past a normal in-flight ceiling. A real
      # burst of legitimate deposits won't sit here long because the
      # client ACKs as soon as it unblinds; sustained growth means
      # ACKs are being dropped (broken client build, concentrated abuse,
      # or a regression on the LiveView path).
      %Rule{
        name: :pending_signatures_high,
        domain: "Mint",
        severity: :warning,
        for_duration: 60_000,
        resolve_after: 3,
        condition: fn -> check_pending_signatures(:high) end
      },
      %Rule{
        name: :pending_signatures_critical,
        domain: "Mint",
        severity: :critical,
        for_duration: 60_000,
        resolve_after: 3,
        condition: fn -> check_pending_signatures(:critical) end
      },
      # Reconciler had to age out and burn an orphan deposit. Each one
      # is real liability that no client redeemed — operator should
      # investigate cumulative count to spot abuse or a deploy regression.
      %Rule{
        name: :orphan_deposits_reconciled,
        domain: "Mint",
        severity: :warning,
        for_duration: 0,
        condition: fn -> check_orphans_reconciled() end
      }
    ]
  end

  defp check_liability_invariant do
    minted = Minted.Reserves.Facade.minted_total()
    burned = Minted.Reserves.Facade.burned_total()

    if burned > minted do
      {:alert, "burned=#{burned}, minted=#{minted}"}
    else
      :ok
    end
  rescue
    e ->
      Logger.warning("Manager: check_liability_invariant failed: #{inspect(e)}")
      :ok
  end

  defp check_reserve_ratio do
    case Cache.get(:proof_of_reserves) do
      :unknown -> :ok
      %{ratio: :infinity} -> :ok
      %{ratio: ratio} when is_number(ratio) and ratio < 1.0 -> {:alert, "ratio=#{Float.round(ratio * 100, 1)}%"}
      _ -> :ok
    end
  rescue
    e ->
      Logger.warning("Manager: check_reserve_ratio failed: #{inspect(e)}")
      :ok
  end

  defp check_liquidity(level) do
    case Cache.get(:liquidity_status) do
      :unknown ->
        :ok

      %{status: status} = info ->
        balance = Map.get(info, :balance_sats, "?")

        case {level, status} do
          {:critical, :critical} -> {:alert, "balance=#{balance} sats"}
          {:low, :low} -> {:alert, "balance=#{balance} sats"}
          {:low, :critical} -> {:alert, "balance=#{balance} sats"}
          _ -> :ok
        end

      _ ->
        :ok
    end
  rescue
    e ->
      Logger.warning("Manager: check_liquidity(#{level}) failed: #{inspect(e)}")
      :ok
  end

  defp check_lightning_reachable do
    case Minted.Lightning.Facade.health_check() do
      :ok -> :ok
      {:error, _} -> {:alert, "status=unreachable"}
    end
  rescue
    e ->
      Logger.debug("Manager: check_lightning_reachable failed: #{inspect(e)}")
      :ok
  end

  defp check_keyset_rotation do
    case Cache.get(:active_keyset) do
      :unknown ->
        # Cache not populated yet — check directly.
        case Minted.Storage.Facade.get_active_keyset() do
          [_ | _] -> :ok
          _ -> {:alert, "keyset=none"}
        end

      %{new_keyset_id: _id, timestamp: ts} ->
        age_days = DateTime.diff(DateTime.utc_now(), ts, :day)

        if age_days > 30 do
          {:alert, "age=#{age_days}d, threshold=30d"}
        else
          :ok
        end

      _ ->
        :ok
    end
  rescue
    _ -> :ok
  end

  defp check_double_spend_rate(level) do
    config =
      Application.get_env(:minted, :alerts_double_spend, [])
      |> Map.new()

    high = Map.get(config, :high, 10)
    critical = Map.get(config, :critical, 50)

    case Cache.get(:double_spend_count) do
      :unknown ->
        :ok

      count when is_integer(count) ->
        case level do
          :high when count >= high and count < critical -> {:alert, "count=#{count}"}
          :critical when count >= critical -> {:alert, "count=#{count}"}
          _ -> :ok
        end

      _ ->
        :ok
    end
  rescue
    e ->
      Logger.warning("Manager: check_double_spend_rate failed: #{inspect(e)}")
      :ok
  end

  defp check_proof_publication do
    case Cache.get(:proof_of_reserves) do
      :unknown ->
        :ok

      %{timestamp: ts} when not is_nil(ts) ->
        age = DateTime.diff(DateTime.utc_now(), ts, :second)
        if age > 20 * 60, do: {:alert, "last_proof=#{div(age, 60)}m"}, else: :ok

      _ ->
        :ok
    end
  rescue
    e ->
      Logger.warning("Manager: check_proof_publication failed: #{inspect(e)}")
      :ok
  end

  # Threshold: 30 minutes. A settled melt is usually acknowledged within
  # seconds; 30 minutes is comfortably above any reasonable Tor-relay
  # propagation delay and well below a typical operator response window.
  @melt_stuck_threshold_seconds 30 * 60

  defp check_melt_settlement_stuck do
    case MintFacade.oldest_quote_in_status(:settlement_unknown) do
      nil ->
        :ok

      %DateTime{} = stamp ->
        age = DateTime.diff(DateTime.utc_now(), stamp, :second)

        if age >= @melt_stuck_threshold_seconds do
          {:alert, "stuck=#{div(age, 60)}m"}
        else
          :ok
        end
    end
  rescue
    e ->
      Logger.warning("Manager: check_melt_settlement_stuck failed: #{inspect(e)}")
      :ok
  end

  defp check_payment_exhausted do
    case Cache.get(:liquidity_status) do
      %{status: :critical, balance_sats: 0} -> {:alert, "balance=0 sats"}
      _ -> :ok
    end
  rescue
    e ->
      Logger.warning("Manager: check_payment_exhausted failed: #{inspect(e)}")
      :ok
  end

  defp check_backup_overdue do
    overdue_ms = Application.get_env(:minted, :backup_overdue_ms, 7_200_000)

    case latest_backup_age_ms() do
      nil -> {:alert, "status=none"}
      age_ms when age_ms > overdue_ms -> {:alert, "last_backup=#{div(age_ms, 60_000)}m"}
      _ -> :ok
    end
  rescue
    e ->
      Logger.warning("Manager: check_backup_overdue failed: #{inspect(e)}")
      :ok
  end

  defp latest_backup_age_ms do
    backup_dir = Minted.Storage.Facade.backup_dir()

    with {:ok, files} <- File.ls(backup_dir),
         [latest | _] <- files |> Enum.filter(&String.starts_with?(&1, "minted-backup-")) |> Enum.sort(:desc),
         {:ok, %{mtime: mtime}} <- File.stat(Path.join(backup_dir, latest)) do
      now_secs = :calendar.datetime_to_gregorian_seconds(:calendar.universal_time())
      file_secs = :calendar.datetime_to_gregorian_seconds(mtime)
      (now_secs - file_secs) * 1_000
    else
      _ -> nil
    end
  end

  defp check_disk_usage(level) do
    threshold = if level == :critical, do: 95, else: 90

    case disk_usage_percent() do
      {:ok, pct} when pct > threshold ->
        {:alert, "usage=#{pct}%, threshold=#{threshold}%"}

      _ ->
        :ok
    end
  rescue
    e ->
      Logger.warning("Manager: check_disk_usage(#{level}) failed: #{inspect(e)}")
      :ok
  end

  defp disk_usage_percent do
    data_dir = StorageFacade.base_dir()

    with {output, 0} <- System.cmd("df", ["--output=pcent", data_dir], stderr_to_stdout: true),
         [_, pct_str] <- Regex.run(~r/(\d+)%/, output),
         {pct, ""} <- Integer.parse(pct_str) do
      {:ok, pct}
    else
      _ -> :error
    end
  end

  # Q7: Check if DETS file is approaching the 2GB hard limit.
  @dets_2gb_limit 2_147_483_648
  @dets_warn_threshold 0.90

  defp check_dets_file_size do
    dets_path = StorageFacade.mint_spent_set_dets_path()

    case File.stat(dets_path) do
      {:ok, %{size: size}} ->
        ratio = size / @dets_2gb_limit

        if ratio > @dets_warn_threshold do
          {:alert, "usage=#{div(size, 1_048_576)}MB, limit=2048MB"}
        else
          :ok
        end

      {:error, :enoent} ->
        :ok

      {:error, _reason} ->
        :ok
    end
  rescue
    e ->
      Logger.warning("Manager: check_dets_file_size failed: #{inspect(e)}")
      :ok
  end

  defp check_rate_limit_surge do
    case Cache.get(:rate_limiter_rejections) do
      :unknown ->
        :ok

      count when is_integer(count) and count > 50 ->
        {:alert, "rejections=#{count}"}

      _ ->
        :ok
    end
  rescue
    e ->
      Logger.warning("Manager: check_rate_limit_surge failed: #{inspect(e)}")
      :ok
  end

  @spent_set_memory_threshold_bytes 500 * 1024 * 1024
  @spent_set_memory_critical_bytes 1024 * 1024 * 1024

  defp check_spent_set_memory(level) do
    total = MintFacade.spent_set_memory_bytes()

    high =
      Application.get_env(
        :minted,
        :spent_set_memory_threshold_bytes,
        @spent_set_memory_threshold_bytes
      )

    critical =
      Application.get_env(
        :minted,
        :spent_set_memory_critical_bytes,
        @spent_set_memory_critical_bytes
      )

    case level do
      :high when total >= high and total < critical ->
        {:alert, format_memory_alert(total, high)}

      :critical when total >= critical ->
        {:alert, format_memory_alert(total, critical)}

      _ ->
        :ok
    end
  rescue
    _ -> :ok
  end

  defp format_memory_alert(total, threshold) do
    mb = div(total, 1_048_576)
    threshold_mb = div(threshold, 1_048_576)
    "usage=#{mb}MB, threshold=#{threshold_mb}MB"
  end

  # --- CPU monitoring ---

  defp check_cpu(:high) do
    pct = Metrics.cpu_usage()

    if pct > 80.0 do
      {:alert, "usage=#{pct}%, threshold=80%"}
    else
      :ok
    end
  end

  defp check_cpu(:critical) do
    pct = Metrics.cpu_usage()

    if pct > 95.0 do
      {:alert, "usage=#{pct}%, threshold=95%"}
    else
      :ok
    end
  end

  # --- Memory monitoring ---

  defp check_memory(:high) do
    pct = Metrics.memory_usage()

    if pct > 80.0 do
      {:alert, "usage=#{pct}%, threshold=80%"}
    else
      :ok
    end
  end

  defp check_memory(:critical) do
    pct = Metrics.memory_usage()

    if pct > 95.0 do
      {:alert, "usage=#{pct}%, threshold=95%"}
    else
      :ok
    end
  end

  # --- Tor monitoring ---

  defp check_tor_reachable do
    case tor_socks_latency_ms() do
      {:ok, _latency_ms} -> :ok
      {:error, _reason} -> {:alert, "port=#{tor_socks_port()}"}
    end
  end

  # Degraded = SOCKS reachable but slow (> 1s), OR control port down.
  # Only reports degraded if SOCKS is actually reachable (otherwise
  # :tor_unreachable fires instead).
  @tor_slow_threshold_ms 1_000

  defp check_tor_degraded do
    case tor_socks_latency_ms() do
      {:error, _reason} ->
        :ok

      {:ok, latency_ms} when latency_ms > @tor_slow_threshold_ms ->
        {:alert, "slow_socks=#{latency_ms}ms"}

      {:ok, _latency_ms} ->
        :ok
    end
  end

  defp tor_socks_latency_ms do
    port = tor_socks_port()
    started = System.monotonic_time(:millisecond)

    case :gen_tcp.connect(~c"127.0.0.1", port, [], 2_000) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        {:ok, System.monotonic_time(:millisecond) - started}

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    error -> {:error, error}
  end

  defp tor_socks_port do
    Application.get_env(:minted, :tor, []) |> Keyword.get(:socks_port, 9050)
  end

  # Pending store size — alerts when in-flight deposit signatures
  # accumulate past expected ceilings. Thresholds are configurable
  # so an operator can tune for their actual deposit volume.
  defp check_pending_signatures(level) do
    count = Minted.Mint.Pending.count()

    config =
      Application.get_env(:minted, :alerts_pending, [])
      |> Map.new()

    high = Map.get(config, :high, 25)
    critical = Map.get(config, :critical, 100)

    case level do
      :high when count >= high and count < critical -> {:alert, "count=#{count}"}
      :critical when count >= critical -> {:alert, "count=#{count}"}
      _ -> :ok
    end
  rescue
    e ->
      Logger.warning("Manager: check_pending_signatures failed: #{inspect(e)}")
      :ok
  end

  # Reconciler counter, sourced from cumulative orphan-burn entries
  # on the WAL. Reads are cached for 30s by Cache so repeated rule
  # evaluations don't fold the WAL on every tick.
  defp check_orphans_reconciled do
    case Cache.get(:orphan_burns_total) do
      n when is_integer(n) and n > 0 ->
        {:alert, "count=#{n}"}

      _ ->
        :ok
    end
  rescue
    e ->
      Logger.warning("Manager: check_orphans_reconciled failed: #{inspect(e)}")
      :ok
  end
end
