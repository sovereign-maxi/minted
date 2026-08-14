defmodule Minted.Telemetry.Metrics.StoreTest do
  @moduledoc "Unit tests for Minted.Telemetry.Metrics.Store."

  use ExUnit.Case, async: false

  alias Minted.Events.EventBus
  alias Minted.Events.Mint, as: MintEvents
  alias Minted.Telemetry.Metrics.Store

  # Store is started by the application supervisor and shared
  # across all tests. Other async tests may publish TokensMinted/TokensBurned
  # events that increment the same counters, so we:
  #   1. Synchronize with :sys.get_state BEFORE reading the "before" snapshot
  #      to drain any pending messages from prior tests.
  #   2. Use >= instead of == for delta assertions since concurrent tests
  #      may increment counters between our snapshot and assertion.

  setup do
    :sys.get_state(Store)
    :ok
  end

  test "get/1 returns nil for unknown keys" do
    assert Store.get(:nonexistent) == nil
    assert Store.get(:bogus_key) == nil
  end

  test "tracks deposit count on TokensMinted" do
    before = Store.get(:deposit_count) || 0

    EventBus.publish(%MintEvents.TokensMinted{
      amount: 1_000,
      count: 1,
      timestamp: DateTime.utc_now()
    })

    :sys.get_state(Store)

    assert Store.get(:deposit_count) >= before + 1
  end

  test "tracks burn count on TokensBurned" do
    before = Store.get(:burn_count) || 0

    EventBus.publish(%MintEvents.TokensBurned{
      amount: 500,
      count: 3,
      timestamp: DateTime.utc_now()
    })

    :sys.get_state(Store)

    assert Store.get(:burn_count) >= before + 3
  end

  test "deposit history entries are maps with :at and :count keys" do
    EventBus.publish(%MintEvents.TokensMinted{
      amount: 100,
      count: 1,
      timestamp: DateTime.utc_now()
    })

    :sys.get_state(Store)

    history = Store.get(:deposit_history)
    assert [_ | _] = history

    entry = hd(history)
    assert is_map(entry)
    assert Map.has_key?(entry, :at)
    assert Map.has_key?(entry, :count)
    assert %DateTime{} = entry.at
    assert is_integer(entry.count)
  end

  test "deposit history is capped at 144 entries" do
    for _ <- 1..150 do
      EventBus.publish(%MintEvents.TokensMinted{
        amount: 1,
        count: 1,
        timestamp: DateTime.utc_now()
      })
    end

    :sys.get_state(Store)

    history = Store.get(:deposit_history)
    assert length(history) <= 144
  end
end
