defmodule MintedAdminWeb.Live.Dashboard do
  @moduledoc """
  Read-only operator dashboard for a single node.

  One page, no tabs. Answers four questions at a glance:

    1. Is the mint solvent?   → reserve ratio, held, outstanding, delta
    2. Is it operational?     → system status, lightning
    3. Is money flowing?      → minted / burned / swapped totals
    4. Anything broken?       → active alerts, curated event stream

  The dashboard lives on a dedicated admin `.onion` with no auth: the onion
  address itself is the capability. Write operations (keyset rotation,
  peer retirement, emergency halt) are deliberately not exposed — do
  those via `iex --remsh` where you can see output and abort.
  """

  use MintedWeb, :live_view

  import Minted.Format, only: [format_sats: 1, short_keyset_id: 1]
  import MintedAdminWeb.Live.Components.Sparkline

  require Logger

  alias Minted.Events.{Display, EventBus, Lightning, Mint, Reserves}
  alias Minted.Events.Telemetry, as: TelemetryEvents
  alias Minted.Lightning.Facade, as: LightningFacade
  alias Minted.Mint.Facade, as: MintFacade
  alias Minted.Mint.House.Facade, as: HouseFacade
  alias Minted.Reserves.Facade, as: ReservesFacade
  alias Minted.Telemetry.Facade, as: TelemetryFacade

  @event_stream_cap 50
  @tick_interval_ms 5_000

  @event_subscriptions [
    Mint.TokensMinted,
    Mint.TokensBurned,
    Mint.TokensSwapped,
    Mint.FeesCollected,
    Mint.DoubleSpendDetected,
    Lightning.InvoicePaid,
    Lightning.PaymentSent,
    Lightning.PaymentFailed,
    Lightning.LiquidityLow,
    Lightning.LiquidityCritical,
    Lightning.LiquidityRecovered,
    Reserves.ProofGenerated,
    TelemetryEvents.AlertFired,
    TelemetryEvents.AlertResolved,
    TelemetryEvents.TorDown,
    TelemetryEvents.TorDegraded,
    TelemetryEvents.TorRecovered,
    TelemetryEvents.SystemStatusChanged,
    TelemetryEvents.KeysetRotated
  ]

  # --- LiveView lifecycle ---

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Enum.each(@event_subscriptions, &EventBus.subscribe/1)
      Process.send_after(self(), :tick, @tick_interval_ms)
    end

    {:ok,
     socket
     |> assign(:page_title, "MINTED - ADMIN")
     |> assign(:event_stream, [])
     |> refresh_snapshot()}
  end

  @impl true
  def handle_info(:tick, socket) do
    Process.send_after(self(), :tick, @tick_interval_ms)
    {:noreply, refresh_snapshot(socket)}
  end

  def handle_info(event, socket) when is_struct(event) do
    # Append the event to the stream cheaply — do NOT trigger a full
    # snapshot refresh on every event. The periodic :tick drives the
    # heavy stat computations (liability snapshot, fee totals, health
    # status, etc.) at most once per @tick_interval_ms regardless of
    # event rate.
    # Sort by the event's own timestamp (not LiveView arrival order) so
    # concurrent events published from different processes don't show
    # scrambled within a second. Descending = newest first.
    entry = format_event(event)

    stream =
      [entry | socket.assigns.event_stream]
      |> Enum.sort_by(& &1.sort_key, :desc)
      |> Enum.take(@event_stream_cap)

    {:noreply, assign(socket, :event_stream, stream)}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def handle_event("clear_events", _params, socket) do
    {:noreply, assign(socket, :event_stream, [])}
  end

  # --- Snapshot refresh ---

  defp refresh_snapshot(socket) do
    liability = safe(fn -> ReservesFacade.liability_snapshot() end, %{minted: 0, burned: 0, outstanding: 0})

    solvency_default = %{status: :pending, pct: 0, held: 0, outstanding: 0, delta: 0, title: "Solvency: unavailable"}
    solvency = safe(fn -> ReservesFacade.solvency() end, solvency_default)

    {ln_balance, ln_status} = safe(fn -> LightningFacade.liquidity_status() end, {0, :unknown})
    ln_inbound = safe(fn -> LightningFacade.inbound_liquidity() end, 0)

    alerts = safe(fn -> TelemetryFacade.active_alerts() end, [])
    status = safe(fn -> TelemetryFacade.system_status() end, :healthy)
    components = safe(fn -> TelemetryFacade.health_components() end, %{})

    assign(socket,
      status: status,
      keyset_id: safe(fn -> MintFacade.active_keyset_id() end, nil),
      held_sats: solvency.held,
      outstanding_sats: solvency.outstanding,
      minted_total: liability.minted,
      burned_total: liability.burned,
      flow_outstanding: liability.outstanding,
      solvency_pct: solvency.pct,
      solvency_delta: solvency.delta,
      solvency_status: solvency.status,
      solvency_title: solvency.title,
      house_earned: safe(fn -> HouseFacade.earned() end, 0),
      house_drawn: safe(fn -> HouseFacade.drawn() end, 0),
      house_in_flight: safe(fn -> HouseFacade.in_flight() end, 0),
      house_withdrawable: safe(fn -> HouseFacade.withdrawable() end, 0),
      lightning_balance: ln_balance,
      lightning_status: ln_status,
      lightning_inbound: ln_inbound,
      active_alerts: alerts,
      footer_pips: footer_pips(components, ln_status),
      sys_metrics: safe(fn -> TelemetryFacade.system_metrics() end, %{}),
      cpu_series: safe(fn -> TelemetryFacade.metrics_series(:cpu_pct, 60) end, []),
      mem_series: safe(fn -> TelemetryFacade.metrics_series(:memory_pct, 60) end, [])
    )
  end

  defp footer_pips(components, _ln_status) do
    [
      %{label: "Lightning", status: pip_status(Map.get(components, :lightning, :unknown))},
      %{label: "Reserves", status: pip_status(Map.get(components, :reserves, :unknown))},
      %{label: "Storage", status: pip_status(Map.get(components, :storage, :unknown))},
      %{label: "Identity", status: pip_status(Map.get(components, :identity, :unknown))},
      %{label: "System", status: pip_status(Map.get(components, :system, :unknown))},
      %{label: "Tor", status: pip_status(Map.get(components, :tor, :unknown))}
    ]
  end

  defp pip_status(:healthy), do: :ok
  defp pip_status(:degraded), do: :degraded
  defp pip_status(:critical), do: :critical
  defp pip_status(:halted), do: :critical
  defp pip_status(_), do: :offline

  defp safe(fun, default) do
    fun.()
  rescue
    _ -> default
  catch
    :exit, _ -> default
  end

  # --- Event formatting for the stream ---
  #
  # Events describe themselves via the Minted.Events.Display protocol.
  # The dashboard is a dumb renderer: it reads domain, label, severity,
  # and detail from the event and maps severity to a CSS colour class.

  defp format_event(event) do
    ts = Map.get(event, :timestamp) || DateTime.utc_now()

    %{
      id: System.unique_integer([:positive, :monotonic]),
      # :sort_key is the microsecond-precision event time, used to
      # order the stream so events published within the same second
      # (often by different processes) display in their true causal
      # order rather than LiveView-arrival order.
      sort_key: DateTime.to_unix(ts, :microsecond),
      time: Calendar.strftime(ts, "%H:%M:%S"),
      domain: Display.domain(event),
      color: severity_color(Display.severity(event)),
      event: Display.label(event),
      detail: Display.detail(event)
    }
  rescue
    Protocol.UndefinedError -> nil
  end

  defp severity_color(:info), do: "ok"
  defp severity_color(:warning), do: "warning"
  defp severity_color(:critical), do: "critical"
  defp severity_color(:emergency), do: "critical"

  # --- Render helpers ---

  defp status_label(:healthy), do: "Healthy"
  defp status_label(:degraded), do: "Degraded"
  defp status_label(:critical), do: "Critical"
  defp status_label(:halted), do: "Halted"
  defp status_label(_), do: "Unknown"

  defp status_class(:healthy), do: "accent"
  defp status_class(:degraded), do: "warning"
  defp status_class(:critical), do: "loss"
  defp status_class(:halted), do: "loss"
  defp status_class(_), do: "muted"

  defp lightning_label(:healthy), do: "CONNECTED"
  defp lightning_label(:low), do: "LOW"
  defp lightning_label(:critical), do: "CRITICAL"
  defp lightning_label(:unknown), do: "UNKNOWN"
  defp lightning_label(other), do: other |> to_string() |> String.upcase()

  defp format_delta(n) when n >= 0, do: "+#{format_sats(n)}"
  defp format_delta(n), do: format_sats(n)

  # --- Render ---

  @impl true
  def render(assigns) do
    ~H"""
    <.header
      logo_text="MINTED"
      logo_href="/admin/dashboard"
      tagline="Bitcoin Without a Trail"
      badge="Admin"
    />

    <.sub_nav
      health_bar={
        %{fill_pct: if(@solvency_status == :pending, do: 0, else: min(@solvency_pct, 100)), title: @solvency_title}
      }
      stats={[
        %{label: "Status", value: status_label(@status), class: status_class(@status)},
        %{label: "Keyset", value: short_keyset_id(@keyset_id)}
      ]}
    />

    <main class="bp-root admin-root">
      <h1 class="bp-sr-only">Admin dashboard</h1>
      <div class="bp-page">
        <.grid cols="4">
          <.panel title="Solvency">
            <.panel_body>
              <.stat_rows rows={[
                %{
                  label: "Ratio",
                  value: if(@solvency_status == :pending, do: "PENDING", else: "#{@solvency_pct}%"),
                  class: if(@solvency_status == :pending, do: "warning", else: solvency_class(@solvency_pct))
                },
                %{label: "Held", value: "#{format_sats(@held_sats)} sats"},
                %{
                  label: "Outstanding",
                  value: "#{format_sats(@outstanding_sats)} sats",
                  class: if(@outstanding_sats < 0, do: "loss", else: "")
                },
                %{label: "Delta", value: "#{format_delta(@solvency_delta)} sats", class: solvency_class(@solvency_pct)}
              ]} />
            </.panel_body>
          </.panel>

          <.panel title="House Income">
            <.panel_body>
              <.stat_rows rows={[
                %{label: "Earned", value: "#{format_sats(@house_earned)} sats"},
                %{label: "Drawn", value: "#{format_sats(@house_drawn)} sats"},
                %{label: "In-flight", value: "#{format_sats(@house_in_flight)} sats"},
                %{label: "Available", value: "#{format_sats(@house_withdrawable)} sats", class: "accent"}
              ]} />
            </.panel_body>
          </.panel>

          <.panel title="Flow (Lifetime)">
            <.panel_body>
              <.stat_rows rows={[
                %{label: "Minted", value: "#{format_sats(@minted_total)} sats", class: "accent"},
                %{label: "Burned", value: "#{format_sats(@burned_total)} sats"},
                %{
                  label: "Outstanding",
                  value: "#{format_sats(@flow_outstanding)} sats",
                  class: if(@flow_outstanding < 0, do: "loss", else: "")
                }
              ]} />
            </.panel_body>
          </.panel>

          <.panel title="Lightning">
            <.panel_body>
              <.stat_rows rows={[
                %{
                  label: "Phoenixd",
                  value: lightning_label(@lightning_status),
                  class: lightning_class(@lightning_status)
                },
                %{label: "Balance", value: "#{format_sats(@lightning_balance)} sats"},
                %{label: "Inbound", value: "#{format_sats(@lightning_inbound)} sats"}
              ]} />
            </.panel_body>
          </.panel>
        </.grid>

        <.grid cols="2">
          <.panel title="System">
            <.panel_body>
              <.sparkline
                data={@cpu_series}
                label="Cpu"
                value={to_string(Map.get(@sys_metrics, :cpu_pct, 0))}
                color="var(--color-accent)"
                max_value={100.0}
              />
              <.sparkline
                data={@mem_series}
                label="Memory"
                value={to_string(Map.get(@sys_metrics, :memory_pct, 0))}
                color="var(--color-warning)"
                max_value={100.0}
              />
            </.panel_body>
          </.panel>

          <.panel title="Resources">
            <.panel_scroll>
              <.stat_rows rows={
                Enum.map(Map.get(@sys_metrics, :disks, []), fn {path, pct} ->
                  %{label: "Disk #{path}", value: "#{pct}%"}
                end) ++
                  [
                    %{label: "Load", value: Map.get(@sys_metrics, :load_avg, "n/a")},
                    %{label: "Beam memory", value: "#{Map.get(@sys_metrics, :beam_memory_mb, 0)} mb"},
                    %{label: "ETS memory", value: "#{Map.get(@sys_metrics, :beam_ets_mb, 0)} mb"},
                    %{label: "Processes", value: "#{Map.get(@sys_metrics, :beam_processes, 0)}"},
                    %{label: "Atoms", value: "#{Map.get(@sys_metrics, :beam_atoms, 0)}"},
                    %{label: "Schedulers", value: "#{Map.get(@sys_metrics, :beam_schedulers, 0)}"},
                    %{label: "Run queue", value: "#{Map.get(@sys_metrics, :beam_run_queue, 0)}"},
                    %{label: "Uptime", value: "#{Map.get(@sys_metrics, :uptime_hours, 0)}h"}
                  ]
              } />
            </.panel_scroll>
          </.panel>
        </.grid>

        <.grid cols="2">
          <.panel title="Active Alerts">
            <.panel_scroll>
              <ol class="mt-activity-feed" role="log" aria-label="Active alerts">
                <li :if={@active_alerts == []} class="bp-empty-state">No active alerts</li>
                <li :for={alert <- @active_alerts} class="mt-activity-row" id={"alert-#{alert.name}"}>
                  <span class={"mt-activity-icon #{severity_icon_class(alert.severity)}"} aria-hidden="true">
                    {String.upcase(to_string(alert.severity))}
                  </span>
                  <span class="mt-activity-detail">
                    {humanise(alert.name)}
                    <span :if={alert.reason} class="mt-activity-dim">({alert.reason})</span>
                  </span>
                  <span class="mt-activity-time">{format_alert_time(alert.fired_at)}</span>
                </li>
              </ol>
            </.panel_scroll>
          </.panel>

          <.panel title="Event Stream">
            <:header_action>
              <a href="#" phx-click="clear_events" class="bp-panel-meta mt-panel-action">CLEAR</a>
            </:header_action>
            <.panel_scroll>
              <ol class="mt-activity-feed" role="log" aria-label="Event stream">
                <li :if={@event_stream == []} class="bp-empty-state">No events yet</li>
                <li :for={entry <- @event_stream} class="mt-activity-row" id={"event-#{entry.id}"}>
                  <span class={"mt-activity-icon #{entry.color}"} aria-hidden="true">
                    {String.upcase(entry.domain)}
                  </span>
                  <span class="mt-activity-detail">
                    {entry.event}
                    <span :if={entry.detail != ""} class="mt-activity-dim">({entry.detail})</span>
                  </span>
                  <span class="mt-activity-time">{entry.time}</span>
                </li>
              </ol>
            </.panel_scroll>
          </.panel>
        </.grid>
      </div>

      <.footer pips={@footer_pips} commit_hash={Minted.Version.git_sha()} />
    </main>
    """
  end

  defp humanise(value) when is_atom(value), do: humanise(to_string(value))

  defp humanise(value) when is_binary(value) do
    value
    |> String.replace("_", " ")
    |> String.split()
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  defp solvency_class(pct) when pct >= 100, do: "accent"
  defp solvency_class(pct) when pct >= 95, do: "warning"
  defp solvency_class(_), do: "loss"

  # Semantic severity class names — each maps to a styled .mt-activity-icon
  # variant in app.css. Colours are shared with wallet counterparts via
  # grouped selectors so the design system stays consistent.
  defp severity_icon_class(:critical), do: "critical"
  defp severity_icon_class(:emergency), do: "critical"
  defp severity_icon_class(:warning), do: "warning"
  defp severity_icon_class(:info), do: "info"
  defp severity_icon_class(_), do: "info"

  defp format_alert_time(%DateTime{} = ts), do: Calendar.strftime(ts, "%H:%M:%S")
  defp format_alert_time(_), do: "--"

  defp lightning_class(:healthy), do: "accent"
  defp lightning_class(:low), do: "warning"
  defp lightning_class(:critical), do: "loss"
  defp lightning_class(_), do: "warning"
end
