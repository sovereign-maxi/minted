defmodule MintedWeb.Live.Helpers do
  @moduledoc false

  use Phoenix.Component

  use Blueprint.Components

  @doc "Renders the standard app header with nav links and badge."
  attr(:active, :atom, required: true)

  def app_header(assigns) do
    ~H"""
    <.header logo_text="MINTED" logo_href="/wallet" tagline="Bitcoin Without a Trail" badge="Beta" />
    """
  end

  @doc "Renders the standard footer with health pips."
  attr(:health, :map, required: true)

  def app_footer(assigns) do
    ~H"""
    <.footer
      pips={[
        %{label: "Tor", status: pip_status(@health.tor)},
        %{label: "Lightning", status: pip_status(@health.lightning)}
      ]}
      commit_hash={Minted.Version.git_sha()}
    />
    """
  end

  # --- Data helpers ---

  @doc "Fetches footer health status from telemetry components."
  def fetch_footer_health do
    components = Minted.Telemetry.Facade.health_components()

    %{
      lightning: map_health(Map.get(components, :lightning, :unknown)),
      tor: map_health(Map.get(components, :tor, :unknown))
    }
  end

  @doc "Returns reserve solvency info for the health bar."
  def reserves_info do
    solvency = Minted.Reserves.Facade.solvency()
    fill = if solvency.status == :pending, do: 0, else: min(solvency.pct, 100)
    %{pct: fill, title: solvency.title}
  end

  @doc "Maps health atom to pip status."
  def pip_status(:ok), do: :ok
  def pip_status(:degraded), do: :degraded
  def pip_status(:critical), do: :critical
  def pip_status(_), do: :offline

  @doc "Standard announcement items for all pages."
  def announcements do
    [
      %{
        message:
          ~s(MINTED is experimental software. <strong>Use at your own risk.</strong> Start with small amounts. See <a href="https://minted.is/protocol/#threat-model" target="_blank" rel="noopener">here</a> for more information.),
        variant: "warning"
      }
    ]
  end

  defp map_health(:healthy), do: :ok
  defp map_health(:degraded), do: :degraded
  defp map_health(:critical), do: :critical
  defp map_health(:halted), do: :critical
  defp map_health(_), do: :offline
end
