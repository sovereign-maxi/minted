defmodule Minted.Telemetry.Supervisor do
  @moduledoc false

  use Supervisor

  def start_link(init_arg) do
    Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    children = [
      {:telemetry_poller,
       measurements: [
         {__MODULE__, :emit_vm_metrics, []}
       ],
       period: :timer.seconds(15),
       name: :minted_telemetry_poller},
      Minted.Telemetry.Events.Handler,
      Minted.Telemetry.Metrics.Collector,
      Minted.Telemetry.Metrics.Store,
      Minted.Telemetry.Health.Cache,
      Minted.Telemetry.Alerts.Manager,
      Minted.Telemetry.Health.System,
      Minted.Telemetry.Metrics.Ring,
      Minted.Telemetry.Events.Stream,
      Minted.Telemetry.Publishers.Nostr
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  @doc false
  def emit_vm_metrics do
    memory = :erlang.memory()

    :telemetry.execute(
      [:minted, :vm, :memory],
      %{total: memory[:total], processes: memory[:processes], ets: memory[:ets]},
      %{}
    )

    {:reductions, reductions} = Process.info(self(), :reductions)
    :telemetry.execute([:minted, :vm, :reductions], %{count: reductions}, %{})
  end
end
