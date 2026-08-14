defmodule Minted.Oracle.Feed do
  @moduledoc """
  GenServer polling BTC/USD prices from multiple exchanges.

  Fetches from Coinbase, Binance, and Kraken in parallel using
  `Task.async_stream`, runs median aggregation via the shared oracle
  package, stores the result in an ETS table, and publishes a
  `PriceUpdated` event via EventBus.
  """

  use GenServer

  require Logger

  alias Minted.Events.EventBus
  alias Minted.Events.Oracle, as: OracleEvents
  alias Oracle.Aggregator
  alias Oracle.Events.PriceTick

  @table Minted.Oracle.Feed
  @default_poll_interval 60_000
  @task_timeout 5_000

  @source_modules %{
    coinbase: Oracle.Sources.Coinbase,
    binance: Oracle.Sources.Binance,
    kraken: Oracle.Sources.Kraken
  }

  # --- Client API ---

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Returns the current BTC/USD price and last-update timestamp from ETS.

  Returns `{price_usd_float, updated_at}` or `{nil, nil}` if unavailable.
  """
  @spec get_price() :: {float() | nil, DateTime.t() | nil}
  def get_price do
    case :ets.whereis(@table) do
      :undefined ->
        {nil, nil}

      _ref ->
        case :ets.lookup(@table, :current) do
          [{:current, price, updated_at}] -> {price, updated_at}
          [] -> {nil, nil}
        end
    end
  end

  @doc "Clears the price ETS table. Intended for test isolation."
  @spec clear() :: :ok
  def clear, do: GenServer.call(__MODULE__, :clear)

  # --- GenServer callbacks ---

  @impl true
  def init(opts) do
    config = Application.get_env(:minted, :price_feed, [])
    enabled = Keyword.get(config, :enabled, true)

    if enabled do
      table =
        if :ets.whereis(@table) == :undefined do
          :ets.new(@table, [:set, :protected, :named_table, read_concurrency: true])
        else
          @table
        end

      poll_interval =
        Keyword.get(opts, :poll_interval) ||
          Keyword.get(config, :poll_interval_ms, @default_poll_interval)

      sources = Keyword.get(config, :sources, [:coinbase, :binance, :kraken])

      send(self(), :poll)

      {:ok, %{table: table, poll_interval: poll_interval, sources: sources}}
    else
      :ignore
    end
  end

  @impl true
  def handle_call(:clear, _from, state) do
    :ets.delete_all_objects(@table)
    {:reply, :ok, state}
  end

  @impl true
  def handle_info(:poll, state) do
    ticks = fetch_prices(state.sources)

    case aggregate(ticks) do
      {:ok, price_float, sources} ->
        now = DateTime.utc_now()
        :ets.insert(@table, {:current, price_float, now})

        EventBus.publish(%OracleEvents.PriceUpdated{
          price_usd: price_float,
          sources: sources,
          timestamp: now
        })

      :error ->
        Logger.warning("Feed: All sources failed or insufficient data, keeping stale price")
    end

    schedule_poll(state.poll_interval)
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # --- Private ---

  defp fetch_prices(sources) do
    source_modules = Enum.map(sources, &Map.get(@source_modules, &1))

    source_modules
    |> Task.async_stream(
      fn source_mod ->
        {source_mod.name(), source_mod.fetch_price(:btc_usd)}
      end,
      timeout: @task_timeout,
      on_timeout: :kill_task
    )
    |> Enum.reduce([], fn
      {:ok, {source, {:ok, price}}}, acc ->
        tick = %PriceTick{
          source: source,
          pair: :btc_usd,
          price: price,
          timestamp: DateTime.utc_now()
        }

        [tick | acc]

      {:ok, {source, {:error, reason}}}, acc ->
        Logger.warning("Feed: #{source} fetch failed: #{inspect(reason)}")
        acc

      {:exit, _reason}, acc ->
        Logger.warning("Feed: Source timed out")
        acc
    end)
  end

  defp aggregate([]), do: :error

  defp aggregate(ticks) do
    case Aggregator.aggregate(ticks, %{strategy: :median, min_sources: 1}) do
      {:ok, [%Oracle.Events.PriceUpdated{price: price, sources: sources} | _]} ->
        {:ok, Decimal.to_float(price), sources}

      {:error, reason, _} ->
        Logger.warning("Feed: Aggregation failed: #{inspect(reason)}")
        :error
    end
  end

  defp schedule_poll(interval) do
    Process.send_after(self(), :poll, interval)
  end
end
