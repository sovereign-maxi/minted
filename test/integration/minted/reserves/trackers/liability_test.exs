defmodule Minted.Reserves.Trackers.LiabilityIntegrationTest do
  @moduledoc "Integration tests for liability tracker mint and burn event accumulation."

  use Minted.IntegrationCase

  alias Minted.Events.EventBus
  alias Minted.Events.Mint
  alias Minted.Reserves.Trackers.Liability

  # Liability is started by the application supervisor and shared
  # across all tests. Other async tests may publish TokensMinted/TokensBurned
  # events that increment the same counters, so we:
  #   1. Synchronize with :sys.get_state BEFORE reading the "before" snapshot
  #      to drain any pending messages from prior tests.
  #   2. Use >= instead of == for delta assertions since concurrent tests
  #      may increment counters between our snapshot and assertion.

  setup do
    # Reset counters to zero and drain any pending messages so each test
    # starts from a known clean state.
    Liability.reset_counters()
    :sys.get_state(Liability)
    :ok
  end

  test "current/0 returns minted, burned, and outstanding" do
    result = Liability.current()
    assert is_integer(result.minted)
    assert is_integer(result.burned)
    assert result.outstanding == max(0, result.minted - result.burned)
  end

  test "tracks minted events" do
    before = Liability.minted_total()

    EventBus.publish(%Mint.TokensMinted{
      amount: 1_000,
      count: 1,
      timestamp: DateTime.utc_now()
    })

    :sys.get_state(Liability)

    assert Liability.minted_total() >= before + 1_000
  end

  test "tracks burned events" do
    before = Liability.burned_total()

    EventBus.publish(%Mint.TokensBurned{
      amount: 500,
      count: 1,
      timestamp: DateTime.utc_now()
    })

    :sys.get_state(Liability)

    assert Liability.burned_total() >= before + 500
  end

  test "outstanding is minted minus burned" do
    before_minted = Liability.minted_total()
    before_burned = Liability.burned_total()

    EventBus.publish(%Mint.TokensMinted{
      amount: 2_000,
      count: 1,
      timestamp: DateTime.utc_now()
    })

    EventBus.publish(%Mint.TokensBurned{
      amount: 300,
      count: 1,
      timestamp: DateTime.utc_now()
    })

    :sys.get_state(Liability)

    current = Liability.current()
    assert current.minted >= before_minted + 2_000
    assert current.burned >= before_burned + 300
    assert current.outstanding == max(0, current.minted - current.burned)
  end
end
