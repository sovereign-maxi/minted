defmodule Minted.Events.EventBusIntegrationTest do
  @moduledoc "Integration tests for EventBus topic derivation and PubSub delivery."

  use Minted.IntegrationCase

  alias Minted.Events.EventBus
  alias Minted.Events.Mint

  describe "topic_for_module/1" do
    test "derives topic from event module" do
      assert EventBus.topic_for_module(Mint.TokensMinted) == "events:mint:tokens_minted"
      assert EventBus.topic_for_module(Mint.TokensBurned) == "events:mint:tokens_burned"
      assert EventBus.topic_for_module(Mint.QuoteUpdated) == "events:mint:quote_updated"

      assert EventBus.topic_for_module(Minted.Events.Lightning.InvoicePaid) ==
               "events:lightning:invoice_paid"

      assert EventBus.topic_for_module(Minted.Events.Storage.KeysetCreated) ==
               "events:storage:keyset_created"
    end
  end

  describe "publish/1 and subscribe/1" do
    test "subscriber receives published struct" do
      :ok = EventBus.subscribe(Mint.TokensMinted)

      event = %Mint.TokensMinted{amount: 1_000, count: 1, timestamp: DateTime.utc_now()}
      :ok = EventBus.publish(event)

      assert_receive %Mint.TokensMinted{amount: 1_000}
    end

    test "subscriber does not receive events from other modules" do
      :ok = EventBus.subscribe(Mint.TokensMinted)

      :ok =
        EventBus.publish(%Mint.TokensBurned{
          amount: 500,
          count: 1,
          timestamp: DateTime.utc_now()
        })

      refute_receive %Mint.TokensMinted{}
    end

    test "messages arrive as bare structs, not {:event, topic, payload}" do
      :ok = EventBus.subscribe(Mint.TokensMinted)

      event = %Mint.TokensMinted{amount: 42, count: 1, timestamp: DateTime.utc_now()}
      :ok = EventBus.publish(event)

      assert_receive %Mint.TokensMinted{amount: 42}
      refute_receive {:event, _, _}
    end
  end

  describe "publish/2 with topic suffix" do
    test "subscriber with suffix receives event" do
      quote_id = "quote_#{System.unique_integer([:positive])}"
      :ok = EventBus.subscribe(Mint.QuoteUpdated, quote_id)

      event = %Mint.QuoteUpdated{
        quote_id: quote_id,
        status: :paid,
        timestamp: DateTime.utc_now()
      }

      :ok = EventBus.publish(event, quote_id)

      assert_receive %Mint.QuoteUpdated{quote_id: ^quote_id, status: :paid}
    end

    test "subscriber without suffix does not receive suffixed event" do
      quote_id = "quote_#{System.unique_integer([:positive])}"
      :ok = EventBus.subscribe(Mint.QuoteUpdated)

      :ok =
        EventBus.publish(
          %Mint.QuoteUpdated{
            quote_id: quote_id,
            status: :paid,
            timestamp: DateTime.utc_now()
          },
          quote_id
        )

      refute_receive %Mint.QuoteUpdated{}
    end
  end

  describe "unsubscribe/1" do
    test "unsubscribed process stops receiving events" do
      :ok = EventBus.subscribe(Mint.TokensMinted)
      :ok = EventBus.unsubscribe(Mint.TokensMinted)

      :ok =
        EventBus.publish(%Mint.TokensMinted{amount: 1, count: 1, timestamp: DateTime.utc_now()})

      refute_receive %Mint.TokensMinted{}
    end
  end

  describe "struct enforcement" do
    test "enforce_keys rejects missing required fields" do
      assert_raise ArgumentError, fn ->
        struct!(Mint.TokensMinted, %{})
      end
    end
  end
end
