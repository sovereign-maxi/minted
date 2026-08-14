defmodule Minted.Telemetry.Events.Handler do
  @moduledoc """
  Maps domain events from all bounded contexts to telemetry metric emissions.

  Subscribes to typed event structs and emits `:telemetry.execute/3` calls
  for each recognized event.
  """

  use GenServer

  require Logger

  alias Minted.Events.EventBus
  alias Minted.Events.{Lightning, Mint, Reserves}

  @event_modules [
    Mint.TokensMinted,
    Mint.TokensBurned,
    Mint.TokensSwapped,
    Mint.QuoteCreated,
    Lightning.LiquidityLow,
    Lightning.LiquidityCritical,
    Lightning.LiquidityRecovered,
    Reserves.ProofGenerated
  ]

  # --- Public API ---

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  # --- GenServer Callbacks ---

  @impl true
  def init(_opts) do
    Enum.each(@event_modules, &EventBus.subscribe/1)
    {:ok, %{}}
  end

  @impl true
  def handle_info(%Mint.TokensMinted{amount: amount}, state) do
    :telemetry.execute([:minted, :tokens, :minted], %{total: amount}, %{})
    {:noreply, state}
  end

  def handle_info(%Mint.TokensBurned{amount: amount}, state) do
    :telemetry.execute([:minted, :tokens, :burned], %{total: amount}, %{})
    {:noreply, state}
  end

  def handle_info(%Mint.TokensSwapped{}, state) do
    :telemetry.execute([:minted, :tokens, :swapped], %{total: 1}, %{})
    {:noreply, state}
  end

  def handle_info(%Lightning.LiquidityLow{balance_sats: balance}, state) do
    :telemetry.execute([:minted, :lightning, :balance_sats], %{value: balance}, %{})
    {:noreply, state}
  end

  def handle_info(%Lightning.LiquidityCritical{balance_sats: balance}, state) do
    :telemetry.execute([:minted, :lightning, :balance_sats], %{value: balance}, %{})
    {:noreply, state}
  end

  def handle_info(%Lightning.LiquidityRecovered{balance_sats: balance}, state) do
    :telemetry.execute([:minted, :lightning, :balance_sats], %{value: balance}, %{})
    {:noreply, state}
  end

  def handle_info(%Reserves.ProofGenerated{ratio: ratio}, state) do
    ratio_val = if ratio == :infinity, do: 1.0, else: ratio
    :telemetry.execute([:minted, :reserve, :ratio], %{value: ratio_val}, %{})
    {:noreply, state}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end
end
