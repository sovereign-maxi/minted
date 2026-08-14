defmodule Minted.Telemetry.Events.StreamTest do
  @moduledoc "Unit tests for Minted.Telemetry.Events.Stream."

  use ExUnit.Case, async: false

  alias Minted.Events.EventBus
  alias Minted.Events.Mint
  alias Minted.Telemetry.Events.Stream

  # Drain any stale telemetry_events messages from the mailbox.
  # Other tests publish EventBus events that Stream batches and
  # broadcasts — without draining, we'd match stale events.
  defp drain_telemetry_mailbox do
    receive do
      {:telemetry_events, _} -> drain_telemetry_mailbox()
    after
      0 -> :ok
    end
  end

  setup do
    on_exit(fn -> Stream.unsubscribe() end)
    :ok
  end

  test "subscribe/0 and unsubscribe/0 work" do
    assert :ok = Stream.subscribe()
    assert :ok = Stream.unsubscribe()
  end

  test "broadcasts batched events on flush" do
    Stream.subscribe()
    drain_telemetry_mailbox()

    EventBus.publish(%Mint.TokensMinted{
      amount: 100,
      count: 1,
      timestamp: DateTime.utc_now()
    })

    EventBus.publish(%Mint.TokensBurned{
      amount: 50,
      count: 1,
      timestamp: DateTime.utc_now()
    })

    # Wait for flush (100ms batch interval + margin)
    assert_receive {:telemetry_events, events}, 500

    assert is_list(events)
    assert events != []

    Enum.each(events, fn event ->
      assert Map.has_key?(event, :topic)
      assert Map.has_key?(event, :timestamp)
      assert Map.has_key?(event, :type)
    end)
  end

  test "sanitizes events to safe fields only" do
    Stream.subscribe()
    drain_telemetry_mailbox()

    # Use a distinctive amount unlikely to collide with other tests.
    unique_amount = 99_777

    EventBus.publish(%Mint.TokensMinted{
      amount: unique_amount,
      count: 1,
      timestamp: DateTime.utc_now()
    })

    # Collect batches until we find our specific event.
    event = receive_event_matching(:tokens_minted, unique_amount, 1_000)

    assert event != nil, "expected to receive our tokens_minted event"
    assert event.type == :tokens_minted
    assert event.amount == unique_amount
    # Struct timestamp is a DateTime but sanitizer replaces with system_time ms.
    assert is_integer(event.timestamp)
  end

  test "logs and emits telemetry on batch overflow" do
    # Attach a telemetry handler to capture the overflow event.
    test_pid = self()
    ref = make_ref()

    :telemetry.attach(
      "test-overflow-#{inspect(ref)}",
      [:minted, :event_stream, :overflow],
      fn _event, measurements, _metadata, _ ->
        send(test_pid, {:overflow, ref, measurements})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach("test-overflow-#{inspect(ref)}") end)

    # Flood the Stream with more than 100 events.
    for i <- 1..110 do
      EventBus.publish(%Mint.TokensMinted{
        amount: i,
        count: 1,
        timestamp: DateTime.utc_now()
      })
    end

    # Wait for overflow telemetry event.
    assert_receive {:overflow, ^ref, %{dropped: dropped}}, 2_000
    assert dropped >= 1
  end

  # Receives telemetry batches until we find an event matching type (and optionally amount).
  defp receive_event_matching(type, amount, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_receive_matching(type, amount, deadline)
  end

  defp do_receive_matching(type, amount, deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {:telemetry_events, events} ->
        match =
          Enum.find(events, fn e ->
            e[:type] == type and (amount == nil or e[:amount] == amount)
          end)

        if match, do: match, else: do_receive_matching(type, amount, deadline)
    after
      remaining -> nil
    end
  end
end
