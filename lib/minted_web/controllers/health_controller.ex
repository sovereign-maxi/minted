defmodule MintedWeb.HealthController do
  @moduledoc """
  Health check endpoints for load balancers and orchestrators.

  - `/health/live`  — always 200 if the BEAM is up
  - `/health/ready` — 200 if System is not halted, 503 otherwise
  """

  use MintedWeb, :controller

  alias Minted.Telemetry.Facade, as: TelemetryFacade

  def live(conn, _params), do: json(conn, %{status: "ok"})

  def ready(conn, _params) do
    if TelemetryFacade.system_status() == :halted do
      conn |> put_status(503) |> json(%{status: "unavailable"})
    else
      conn |> put_status(200) |> json(%{status: "ok"})
    end
  end
end
