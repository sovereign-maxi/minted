defmodule Minted.Lightning.ETSHolder do
  @moduledoc false

  # Long-lived GenServer that owns ETS tables for the Lightning context.
  # Prevents table destruction when short-lived processes (Plug handlers,
  # Task workers) would otherwise be the table owner.
  #
  # Security note: Tables are `:public` because worker processes need to
  # write to tables owned by this holder. ETS access levels are not a
  # security boundary in the BEAM — access control is enforced at the
  # application API layer, not the ETS layer.

  use GenServer

  require Logger

  @tables [
    # Executor-owned tables that MUST outlive any single caller. Both
    # were being lazy-created by whichever process called
    # `execute/1` first — typically a Phoenix connection process —
    # and destroyed when that process exited. When IdMap died,
    # PaymentSent/Exhausted bridge lookups missed and every in-flight
    # melt fell through to :settlement_unknown; when InFlight died,
    # the concurrency cap silently reset to 0 while payments were
    # still executing.
    {Minted.Lightning.Executor.IdMap, [:named_table, :set, :public, read_concurrency: true]},
    {Minted.Lightning.Executor.InFlight, [:named_table, :set, :public, write_concurrency: true]},
    # FireBird.Webhook's dedup + rate-limit tables. Created here so
    # they're owned by a long-lived process rather than by whichever
    # connection process happens to service the first webhook — table
    # loss under the previous "lazy-create on first use" pattern
    # meant every second webhook after a connection exit failed dedup.
    {FireBird.Webhook, [:named_table, :set, :public, read_concurrency: true]},
    {FireBird.Webhook.RateLimit, [:named_table, :set, :public, write_concurrency: true]}
  ]

  # Keys the executor's in-flight counter table is seeded with on
  # boot. Both counters start at 0; the executor updates them via
  # `:ets.update_counter/4` and expects them present.
  @in_flight_seed_keys [:total_in_flight, :count_in_flight]

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    recreated =
      for {name, table_opts} <- @tables do
        if :ets.whereis(name) == :undefined do
          :ets.new(name, table_opts)
          true
        else
          false
        end
      end

    # A holder restart wiped and recreated the executor/webhook tables:
    # the payment-id map and in-flight counters reset while payments may
    # still be executing. Awaiting melts fall through to soft-timeout →
    # settlement_unknown (fail-closed), but the concurrency cap is
    # under-counted until settlement — be loud. The persistent_term flag
    # suppresses the noise on a node's first boot.
    if Enum.any?(recreated) and :persistent_term.get({__MODULE__, :tables_were_up}, false) do
      Logger.warning("ETSHolder: tables recreated after restart — idempotency map and in-flight counters reset")

      :telemetry.execute([:minted, :lightning, :ets_holder, :tables_recreated], %{count: 1}, %{})
    end

    :persistent_term.put({__MODULE__, :tables_were_up}, true)

    seed_in_flight_counters()

    {:ok, :ok}
  rescue
    ArgumentError -> {:ok, :ok}
  end

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  # --- Private ---

  defp seed_in_flight_counters do
    Enum.each(@in_flight_seed_keys, fn key ->
      :ets.insert_new(Minted.Lightning.Executor.InFlight, {key, 0})
    end)
  end
end
