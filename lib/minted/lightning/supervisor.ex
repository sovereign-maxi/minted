defmodule Minted.Lightning.Supervisor do
  @moduledoc false

  use Supervisor

  alias Minted.Lightning.Adapters.Client

  def start_link(init_arg) do
    Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    # The ETS holder always runs — even under :skip_lightning_children —
    # because it owns Executor-side tables (IdMap, InFlight) and the
    # FireBird.Webhook dedup + rate-limit tables. Skipping the holder
    # leaves the executor tables absent (every `execute/1` trips
    # ArgumentError → `:too_many_concurrent`) and leaves webhook state
    # ephemeral in whichever short-lived process serves the first
    # webhook. The Breaker always runs too: `Breaker.call/2` fails
    # closed when the GenServer is absent, and Manager/Resolver paths
    # depend on it in every environment.
    base_children = [Minted.Lightning.ETSHolder, Minted.Lightning.Breaker]

    children =
      if Application.get_env(:minted, :skip_lightning_children, false) do
        base_children
      else
        config = Application.get_env(:minted, :lightning, [])
        pubsub_name = FireBird.PubSub.Lightning

        high_watermark =
          Keyword.get(config, :liquidity_high_watermark, 1_000_000)

        low_watermark =
          Keyword.get(config, :liquidity_low_watermark, 100_000)

        base_children ++
          [
            {FireBird.Supervisor,
             client: Client.client_tuple(),
             pubsub_name: pubsub_name,
             name: FireBird.Supervisor.Lightning,
             high_watermark: high_watermark,
             low_watermark: low_watermark,
             critical_watermark: Keyword.get(config, :liquidity_critical_sats, 10_000),
             poll_interval: Keyword.get(config, :liquidity_poll_interval, 30_000),
             invoice_poll_interval: Keyword.get(config, :invoice_poll_interval, 3_000),
             max_concurrent: Keyword.get(config, :max_concurrent, 5),
             wal: {Minted.Lightning.Adapters.WAL, []}},
            {Minted.Lightning.Manager, pubsub: pubsub_name},
            {Minted.Lightning.Bridge, pubsub: pubsub_name},
            {Minted.Lightning.Settlement.Resolver,
             poll_interval_ms: Keyword.get(config, :settlement_resolver_poll_ms, 60_000),
             min_age_ms: Keyword.get(config, :settlement_resolver_min_age_ms, 600_000)}
          ]
      end

    Supervisor.init(children,
      strategy: :rest_for_one,
      max_restarts: 10,
      max_seconds: 60
    )
  end

  @doc """
  Returns true if all supervised children are alive.
  """
  @spec healthy?() :: boolean()
  def healthy? do
    case Process.whereis(__MODULE__) do
      nil ->
        false

      _pid ->
        __MODULE__
        |> Supervisor.which_children()
        |> Enum.all?(fn {_id, child, _type, _modules} ->
          is_pid(child)
        end)
    end
  end
end
