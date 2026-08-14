defmodule Minted.Lightning.Monitor do
  @moduledoc """
  Facade reading FireBird's `FireBird.Monitor` ETS table.

  NOT a GenServer — `FireBird.Monitor` (started by
  `FireBird.Supervisor`) owns the polling GenServer and ETS table.

  This module provides the same public API as the old Monitor
  so call sites require zero changes.
  """

  @table FireBird.Monitor

  @doc """
  Returns the current liquidity status.

  Reads balance from FireBird's ETS table and evaluates thresholds from
  application config. Returns `{balance_sats, status_atom}` or `{0, :unknown}`.
  """
  @spec get_status() :: {non_neg_integer(), :healthy | :low | :critical | :unknown}
  def get_status do
    case :ets.whereis(@table) do
      :undefined ->
        {0, :unknown}

      _ref ->
        case :ets.lookup(@table, :balance) do
          [{:balance, balance}] ->
            {balance, evaluate_threshold(balance)}

          [] ->
            {0, :unknown}
        end
    end
  end

  @doc """
  Returns the current inbound liquidity in sats (capacity to receive deposits).

  Summed across all Normal channels. Returns 0 if unknown.
  """
  @spec get_inbound_liquidity() :: non_neg_integer()
  def get_inbound_liquidity do
    case :ets.whereis(@table) do
      :undefined ->
        0

      _ref ->
        case :ets.lookup(@table, :inbound_liquidity) do
          [{:inbound_liquidity, sats}] -> sats
          [] -> 0
        end
    end
  end

  @doc """
  Returns `{:ok, inbound_liquidity_sats}` when the monitor has data,
  or `:unknown` when it isn't running or has never polled. Callers
  pricing splice fees must treat `:unknown` as "cannot rule out a
  splice" — never as zero liquidity.
  """
  @spec inbound_liquidity() :: {:ok, non_neg_integer()} | :unknown
  def inbound_liquidity do
    case :ets.whereis(@table) do
      :undefined ->
        :unknown

      _ref ->
        case :ets.lookup(@table, :inbound_liquidity) do
          [{:inbound_liquidity, sats}] -> {:ok, sats}
          [] -> :unknown
        end
    end
  end

  @doc """
  Returns true if the current balance is >= the requested amount.
  """
  @spec sufficient?(non_neg_integer()) :: boolean()
  def sufficient?(amount_sats) when is_integer(amount_sats) do
    {balance, status} = get_status()
    status != :unknown and balance >= amount_sats
  end

  @doc """
  Clears all entries from the liquidity ETS table. Intended for use in tests.
  """
  @spec clear() :: :ok
  def clear do
    case :ets.whereis(@table) do
      :undefined -> :ok
      _ref -> :ets.delete_all_objects(@table)
    end

    :ok
  end

  @doc """
  Sets the current liquidity status in the ETS table. Intended for use in tests
  to seed the table with a known balance and status without going through polling.
  """
  @spec set_status(non_neg_integer(), atom(), DateTime.t()) :: :ok
  def set_status(balance, _status, _updated_at \\ DateTime.utc_now()) do
    case :ets.whereis(@table) do
      :undefined ->
        :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
        :ets.insert(@table, {:balance, balance})

      _ref ->
        :ets.insert(@table, {:balance, balance})
    end

    :ok
  end

  defp evaluate_threshold(balance) do
    {high, low} = thresholds()

    cond do
      balance >= high -> :healthy
      balance >= low -> :low
      true -> :critical
    end
  end

  defp thresholds do
    config = Application.get_env(:minted, :lightning, [])

    high_watermark =
      Keyword.get(
        config,
        :liquidity_high_watermark,
        Keyword.get(config, :liquidity_low_sats, 100_000)
      )

    low_watermark =
      Keyword.get(
        config,
        :liquidity_low_watermark,
        Keyword.get(config, :liquidity_critical_sats, 10_000)
      )

    {high_watermark, low_watermark}
  end
end
