defmodule Minted.Reserves.Trackers.FeesIntegrationTest do
  @moduledoc "Integration tests for fee tracker event handling and snapshot accumulation."

  use Minted.IntegrationCase

  alias Minted.Events.EventBus
  alias Minted.Events.Mint
  alias Minted.Reserves.Trackers.Fees

  # Fees is started by the application supervisor and shared
  # across all tests. We synchronize with :sys.get_state to drain
  # any pending messages before reading snapshots.

  setup do
    :sys.get_state(Fees)
    :ok
  end

  test "current/0 returns total_collected and event_count" do
    result = Fees.current()
    assert is_integer(result.total_collected)
    assert is_integer(result.event_count)
  end

  test "tracks FeesCollected events" do
    before = Fees.current()

    EventBus.publish(%Mint.FeesCollected{
      amount: 20,
      quote_id: "test_quote_1",
      timestamp: DateTime.utc_now()
    })

    :sys.get_state(Fees)

    after_state = Fees.current()
    assert after_state.total_collected >= before.total_collected + 20
    assert after_state.event_count >= before.event_count + 1
  end

  test "accumulates multiple fee events" do
    before = Fees.current()

    for i <- 1..3 do
      EventBus.publish(%Mint.FeesCollected{
        amount: 10,
        quote_id: "test_quote_multi_#{i}",
        timestamp: DateTime.utc_now()
      })
    end

    :sys.get_state(Fees)

    after_state = Fees.current()
    assert after_state.total_collected >= before.total_collected + 30
    assert after_state.event_count >= before.event_count + 3
  end
end
