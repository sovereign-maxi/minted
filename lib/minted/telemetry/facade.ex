defmodule Minted.Telemetry.Facade do
  @moduledoc false

  alias Minted.Telemetry.Alerts.Manager, as: AlertsManager
  alias Minted.Telemetry.Health.System
  alias Minted.Telemetry.Metrics.Ring

  @doc "Sets the system to halted state with a reason."
  @spec set_halted(String.t()) :: :ok
  def set_halted(reason) do
    System.set_halted(reason)
  end

  @doc """
  Returns the current aggregate system health status as an atom such
  as :healthy, :degraded, or :halted. Returns :unknown when the health
  system is unreachable — deliberately not :healthy, so dashboards
  never render green while the telemetry pipeline is down.
  """
  @spec system_status() :: atom()
  def system_status do
    System.status()
  rescue
    _ -> :unknown
  catch
    :exit, _ -> :unknown
  end

  @doc """
  Returns the per-component health breakdown as a map. Used by the
  wallet and admin LiveViews to render component-level status. Returns
  an empty map if the health system is not running (e.g. during
  recovery or shutdown) so callers can render a safe fallback.
  """
  @spec health_components() :: map()
  def health_components do
    System.components()
  rescue
    _ -> %{}
  catch
    :exit, _ -> %{}
  end

  @doc """
  Returns the list of currently active alerts. Used by the admin
  dashboard to render the operator alert panel.
  """
  @spec active_alerts() :: [map()]
  def active_alerts do
    AlertsManager.active_alerts()
  rescue
    _ -> []
  catch
    :exit, _ -> []
  end

  @doc "Returns the latest system metrics snapshot."
  @spec system_metrics() :: map()
  def system_metrics do
    Ring.latest() || %{}
  rescue
    _ -> %{}
  catch
    :exit, _ -> %{}
  end

  @doc "Returns a time series for a metric key (list of {timestamp, value})."
  @spec metrics_series(atom(), pos_integer()) :: [{integer(), number()}]
  def metrics_series(key, limit \\ 360) do
    Ring.series(key, limit)
  rescue
    _ -> []
  catch
    :exit, _ -> []
  end
end
