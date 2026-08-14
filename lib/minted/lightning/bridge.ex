defmodule Minted.Lightning.Bridge do
  @moduledoc """
  Bridges FireBird package events to the application EventBus.

  Subscribes to `FireBird.PubSub` topics (`:invoice`, `:payment`,
  `:liquidity`) and republishes matching events as
  `Minted.Events.Lightning.*` structs via `Minted.Events.EventBus`.
  """

  use GenServer

  require Logger

  alias Minted.Events.EventBus
  alias Minted.Events.Lightning, as: LightningEvents
  alias Minted.Lightning.Executor
  alias Minted.Lightning.Manager

  @topics [:invoice, :payment, :liquidity]

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl GenServer
  def init(opts) do
    pubsub = Keyword.fetch!(opts, :pubsub)

    for topic <- @topics do
      FireBird.PubSub.subscribe(pubsub, topic)
    end

    {:ok, %{pubsub: pubsub, previous_liquidity_status: :unknown}}
  end

  # --- Invoice Events ---

  @impl GenServer
  def handle_info(
        {FireBird.PubSub, :invoice, %FireBird.Events.InvoicePaid{} = event},
        state
      ) do
    payment_hash_hex = Base.encode16(event.payment_hash, case: :lower)

    # Look up quote_id, preimage, and expected amount from Manager's state.
    # FireBird now emits :received_sats separately from :amount_sats (see
    # FireBird.Events.InvoicePaid). :amount_sats is what the invoice was
    # minted for; :received_sats is what phoenixd actually reported as
    # landed. We enforce received >= expected here as a second line of
    # defense — FireBird's own polling reconciler fails closed when the
    # field is missing, but a compromised or downgraded phoenixd could
    # still return `received_sats < amount_sats` and we refuse to credit.
    case Manager.get_invoice(payment_hash_hex) do
      {:ok, invoice} ->
        if event.received_sats >= invoice.amount_sats do
          EventBus.publish(%LightningEvents.InvoicePaid{
            payment_hash: payment_hash_hex,
            amount_sats: invoice.amount_sats,
            preimage: invoice.preimage,
            quote_id: invoice.quote_id,
            timestamp: event.paid_at
          })
        else
          Logger.error(
            "Bridge: REJECTING underpaid invoice #{payment_hash_hex} — " <>
              "expected=#{invoice.amount_sats} received=#{event.received_sats}"
          )

          :telemetry.execute(
            [:minted, :lightning, :invoice, :underpaid],
            %{expected_sats: invoice.amount_sats, received_sats: event.received_sats},
            %{payment_hash: payment_hash_hex}
          )
        end

      {:error, _} ->
        # Unknown invoice — no expected amount to check against. Log
        # loudly; the downstream mint quote pipeline requires a
        # matching quote_id anyway.
        Logger.warning(
          "Bridge: InvoicePaid for unknown payment_hash #{payment_hash_hex} — " <>
            "amount=#{event.amount_sats} received=#{event.received_sats}"
        )

        EventBus.publish(%LightningEvents.InvoicePaid{
          payment_hash: payment_hash_hex,
          amount_sats: event.amount_sats,
          preimage: nil,
          quote_id: nil,
          timestamp: event.paid_at
        })
    end

    {:noreply, state}
  end

  def handle_info(
        {FireBird.PubSub, :invoice, %FireBird.Events.InvoiceExpired{} = event},
        state
      ) do
    EventBus.publish(%LightningEvents.InvoiceExpired{
      payment_hash: Base.encode16(event.payment_hash, case: :lower),
      amount_sats: event.amount_sats,
      timestamp: event.expired_at
    })

    {:noreply, state}
  end

  # --- Payment Events ---

  def handle_info(
        {FireBird.PubSub, :payment, %FireBird.Events.PaymentSent{} = event},
        state
      ) do
    payment_id = Executor.lookup_payment_id(event.payment_hash)
    preimage_hex = Base.encode16(event.preimage, case: :lower)

    sent_event = %LightningEvents.PaymentSent{
      payment_id: payment_id,
      bolt11: nil,
      amount_sats: event.amount_sats,
      preimage: preimage_hex,
      routing_fee_sat: event.fee_sats,
      timestamp: DateTime.utc_now()
    }

    EventBus.publish(sent_event)
    EventBus.publish(sent_event, payment_id)

    {:noreply, state}
  end

  def handle_info(
        {FireBird.PubSub, :payment, %FireBird.Events.PaymentFailed{} = event},
        state
      ) do
    payment_id = Executor.lookup_payment_id(event.payment_hash)

    EventBus.publish(%LightningEvents.PaymentFailed{
      payment_id: payment_id,
      error: event.reason,
      attempt: event.attempt,
      will_retry: true,
      timestamp: DateTime.utc_now()
    })

    {:noreply, state}
  end

  def handle_info(
        {FireBird.PubSub, :payment, %FireBird.Events.PaymentExhausted{} = event},
        state
      ) do
    payment_id = Executor.lookup_payment_id(event.payment_hash)

    exhausted_event = %LightningEvents.PaymentExhausted{
      payment_id: payment_id,
      error: event.reason,
      attempts: event.attempts,
      timestamp: DateTime.utc_now()
    }

    EventBus.publish(exhausted_event)
    EventBus.publish(exhausted_event, payment_id)

    {:noreply, state}
  end

  def handle_info(
        {FireBird.PubSub, :payment, %FireBird.Events.PaymentUnknown{} = event},
        state
      ) do
    payment_id = Executor.lookup_payment_id(event.payment_hash)

    unknown_event = %LightningEvents.PaymentUnknown{
      payment_id: payment_id,
      error: event.reason,
      attempt: event.attempt,
      phoenixd_id: event.phoenixd_id,
      timestamp: DateTime.utc_now()
    }

    EventBus.publish(unknown_event)
    EventBus.publish(unknown_event, payment_id)

    {:noreply, state}
  end

  # --- Liquidity Events ---

  def handle_info(
        {FireBird.PubSub, :liquidity, %FireBird.Events.LiquidityLow{} = event},
        state
      ) do
    EventBus.publish(%LightningEvents.LiquidityLow{
      balance_sats: event.balance_sats,
      previous_status: state.previous_liquidity_status,
      current_status: :low,
      timestamp: DateTime.utc_now()
    })

    {:noreply, %{state | previous_liquidity_status: :low}}
  end

  def handle_info(
        {FireBird.PubSub, :liquidity, %FireBird.Events.LiquidityCritical{} = event},
        state
      ) do
    EventBus.publish(%LightningEvents.LiquidityCritical{
      balance_sats: event.balance_sats,
      previous_status: state.previous_liquidity_status,
      current_status: :critical,
      timestamp: DateTime.utc_now()
    })

    {:noreply, %{state | previous_liquidity_status: :critical}}
  end

  def handle_info(
        {FireBird.PubSub, :liquidity, %FireBird.Events.LiquidityRecovered{} = event},
        state
      ) do
    EventBus.publish(%LightningEvents.LiquidityRecovered{
      balance_sats: event.balance_sats,
      previous_status: state.previous_liquidity_status,
      current_status: :healthy,
      timestamp: DateTime.utc_now()
    })

    {:noreply, %{state | previous_liquidity_status: :healthy}}
  end

  # --- Catch-all for unhandled FireBird events ---

  def handle_info({FireBird.PubSub, _topic, _event}, state) do
    {:noreply, state}
  end
end
