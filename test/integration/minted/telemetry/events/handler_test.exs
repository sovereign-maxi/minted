defmodule Minted.Telemetry.Events.HandlerIntegrationTest do
  @moduledoc "Integration tests for telemetry event handler dispatch and metric emission."

  use Minted.IntegrationCase

  alias Minted.Events.EventBus
  alias Minted.Events.{Lightning, Mint, Reserves}

  test "handles tokens_minted events" do
    ref = :telemetry_test.attach_event_handlers(self(), [[:minted, :tokens, :minted]])

    EventBus.publish(%Mint.TokensMinted{
      amount: 1_000,
      count: 1,
      timestamp: DateTime.utc_now()
    })

    :sys.get_state(Minted.Telemetry.Events.Handler)

    assert_received {[:minted, :tokens, :minted], ^ref, %{total: 1_000}, %{}}
  end

  test "handles tokens_burned events" do
    ref = :telemetry_test.attach_event_handlers(self(), [[:minted, :tokens, :burned]])

    EventBus.publish(%Mint.TokensBurned{
      amount: 500,
      count: 1,
      timestamp: DateTime.utc_now()
    })

    :sys.get_state(Minted.Telemetry.Events.Handler)

    assert_received {[:minted, :tokens, :burned], ^ref, %{total: 500}, %{}}
  end

  test "handles tokens_swapped events" do
    ref = :telemetry_test.attach_event_handlers(self(), [[:minted, :tokens, :swapped]])

    EventBus.publish(%Mint.TokensSwapped{
      amount: 100,
      count: 2,
      timestamp: DateTime.utc_now()
    })

    :sys.get_state(Minted.Telemetry.Events.Handler)

    assert_received {[:minted, :tokens, :swapped], ^ref, %{total: 1}, %{}}
  end

  test "handles liquidity events" do
    ref =
      :telemetry_test.attach_event_handlers(self(), [[:minted, :lightning, :balance_sats]])

    EventBus.publish(%Lightning.LiquidityLow{
      balance_sats: 50_000,
      previous_status: :healthy,
      current_status: :low,
      timestamp: DateTime.utc_now()
    })

    :sys.get_state(Minted.Telemetry.Events.Handler)

    assert_received {[:minted, :lightning, :balance_sats], ^ref, %{value: 50_000}, %{}}
  end

  test "handles proof_generated events" do
    ref = :telemetry_test.attach_event_handlers(self(), [[:minted, :reserve, :ratio]])

    EventBus.publish(%Reserves.ProofGenerated{
      proof_id: "proof_1",
      ratio: 1.05,
      status: :healthy,
      timestamp: DateTime.utc_now()
    })

    :sys.get_state(Minted.Telemetry.Events.Handler)

    assert_received {[:minted, :reserve, :ratio], ^ref, %{value: 1.05}, %{}}
  end

  test "ignores unknown events without crashing" do
    # Send a message that is not a subscribed struct.
    send(Process.whereis(Minted.Telemetry.Events.Handler), {:some, :unknown, :message})
    :sys.get_state(Minted.Telemetry.Events.Handler)
    # No crash — the handler is still alive.
    assert Process.alive?(Process.whereis(Minted.Telemetry.Events.Handler))
  end
end
