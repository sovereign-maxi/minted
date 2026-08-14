defmodule Minted.Lightning.Executor do
  @moduledoc """
  Adapter module delegating payment execution to `FireBird.Executor`.

  NOT a GenServer — performs preflight checks then submits payments to the
  FireBird.Executor GenServer. Maintains an ETS `id_map` table
  mapping payment IDs to FireBird payment hashes.
  """

  require Logger

  alias Minted.Events.EventBus
  alias Minted.Events.Lightning, as: LightningEvents
  alias Minted.Lightning.Adapters.Client
  alias Minted.Lightning.Monitor
  alias Minted.Lightning.Payment

  @await_timeout_ms Application.compile_env(:minted, :melt_settlement_timeout_ms, 120_000)

  @payment_table Minted.Lightning.Executor
  @id_map_table Minted.Lightning.Executor.IdMap
  @in_flight_table Minted.Lightning.Executor.InFlight
  @in_flight_key :total_in_flight
  @in_flight_count_key :count_in_flight
  @max_concurrent 5

  # --- Client API ---

  @doc """
  Begins execution of an outbound payment.

  Runs pre-flight checks, converts to FireBird.Payment, submits to
  FireBird.Executor, and returns `{:ok, payment}` or `{:error, reason}`.
  """
  @spec execute(Payment.t(), keyword()) :: {:ok, Payment.t()} | {:error, term()}
  def execute(%Payment{} = payment, _opts \\ []) do
    case preflight_check(payment) do
      :ok ->
        fb_payment = Payment.to_firebird(payment)

        case submit_to_firebird(fb_payment) do
          :ok ->
            # Store ID mapping for event bridge (forward + reverse for O(1) lookup).
            :ets.insert(@id_map_table, {fb_payment.payment_hash, payment.id})
            :ets.insert(@id_map_table, {{:reverse, payment.id}, fb_payment.payment_hash})

            {:ok, in_flight} = Payment.mark_in_flight(payment)
            store_payment(in_flight)

            {:ok, in_flight}

          {:error, reason} ->
            release_liquidity(payment.amount_sats)
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Executes a payment and blocks until it settles (PaymentSent) or fails
  (PaymentExhausted / timeout).

  Subscribes to payment-specific EventBus topics, dispatches via `execute/1`,
  then waits for the settlement event. Timeout is slightly above FireBird's
  30 s HTTP timeout to avoid racing the upstream.
  """
  @spec execute_and_await(Payment.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def execute_and_await(%Payment{} = payment, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @await_timeout_ms)
    payment_id = payment.id
    amount_sats = payment.amount_sats

    EventBus.subscribe(LightningEvents.PaymentSent, payment_id)
    EventBus.subscribe(LightningEvents.PaymentExhausted, payment_id)
    EventBus.subscribe(LightningEvents.PaymentUnknown, payment_id)

    try do
      case execute(payment) do
        {:ok, in_flight} ->
          Process.put(:liquidity_reserved, amount_sats)
          Minted.Clock.send_after(self(), {:payment_timeout, payment_id}, timeout)
          await_settlement(payment_id, in_flight)

        {:error, _} = err ->
          err
      end
    after
      if Process.delete(:liquidity_reserved), do: release_liquidity(amount_sats)
      EventBus.unsubscribe(LightningEvents.PaymentSent, payment_id)
      EventBus.unsubscribe(LightningEvents.PaymentExhausted, payment_id)
      EventBus.unsubscribe(LightningEvents.PaymentUnknown, payment_id)
    end
  end

  defp await_settlement(payment_id, in_flight) do
    receive do
      %LightningEvents.PaymentSent{payment_id: ^payment_id} = event ->
        {:ok, %{payment: in_flight, preimage: event.preimage, routing_fee: event.routing_fee_sat}}

      %LightningEvents.PaymentExhausted{payment_id: ^payment_id} = event ->
        {:error, {:payment_exhausted, event.error}}

      # Ambiguous outcome — MUST NOT release reservation. Caller
      # transitions the quote to :settlement_unknown so the operator
      # (or a future reconciler) can resolve against phoenixd.
      %LightningEvents.PaymentUnknown{payment_id: ^payment_id} = event ->
        Logger.error(
          "Executor: payment outcome unknown, reservation held, " <>
            "payment_id=#{payment_id}, phoenixd_id=#{inspect(event.phoenixd_id)}"
        )

        {:error, {:settlement_unknown, event.error}}

      {:payment_timeout, ^payment_id} ->
        Logger.error("Executor: timeout waiting for payment to settle, payment_id=#{payment_id}")

        :telemetry.execute(
          [:minted, :lightning, :payment, :timeout],
          %{count: 1},
          %{payment_id: payment_id, type: :soft_timeout}
        )

        {:error, :settlement_timeout}

      {:direct_payment_result, _hash, result} ->
        # Direct-execution path is used when FireBird.Supervisor
        # isn't running (typically tests). Translate the client response
        # into the same shape the event path returns so callers see
        # genuine outcomes.
        translate_direct_result(result, in_flight)
    after
      @await_timeout_ms + 5_000 ->
        Logger.error("Executor: hard timeout, payment_id=#{payment_id}")

        :telemetry.execute(
          [:minted, :lightning, :payment, :timeout],
          %{count: 1},
          %{payment_id: payment_id, type: :hard_timeout}
        )

        {:error, :settlement_timeout}
    end
  end

  # Direct-execution test-path translator. Mirrors the executor's
  # PubSub-driven contract shape so tests don't have to distinguish
  # the two paths.
  defp translate_direct_result({:ok, resp}, in_flight) when is_map(resp) do
    preimage = resp["paymentPreimage"] || resp["preimage"]
    routing_fee = resp["routingFeeSat"] || resp["fees"] || 0

    if is_binary(preimage) and preimage != "" do
      {:ok, %{payment: in_flight, preimage: preimage, routing_fee: routing_fee}}
    else
      {:error, {:settlement_unknown, :direct_response_missing_preimage}}
    end
  end

  defp translate_direct_result({:error, reason}, _in_flight) do
    # Any client-side error in the direct path is a definitive
    # negative (no phoenixd background settlement to worry about
    # racing against; the direct path is one-shot).
    {:error, {:payment_exhausted, reason}}
  end

  defp translate_direct_result(_other, _in_flight) do
    {:error, {:settlement_unknown, :direct_response_malformed}}
  end

  @doc """
  Clears all payments. Intended for use in tests.
  """
  @spec clear() :: :ok
  def clear do
    case :ets.whereis(@payment_table) do
      :undefined -> :ok
      _ref -> :ets.delete_all_objects(@payment_table)
    end

    case :ets.whereis(@id_map_table) do
      :undefined -> :ok
      _ref -> :ets.delete_all_objects(@id_map_table)
    end

    case :ets.whereis(@in_flight_table) do
      :undefined -> :ok
      _ref -> :ets.delete_all_objects(@in_flight_table)
    end

    :ok
  end

  @doc """
  Retrieves payment status by ID.
  """
  @spec get_payment(String.t()) :: {:ok, Payment.t()} | {:error, :not_found}
  def get_payment(payment_id) do
    # First try our id_map to find the FireBird payment.
    case find_fb_payment_hash(payment_id) do
      {:ok, fb_hash} ->
        case FireBird.Executor.lookup(@payment_table, fb_hash) do
          {:ok, fb_payment} ->
            # Re-read our stored payment and merge status.
            {:ok, merge_payment_status(payment_id, fb_payment)}

          {:error, :not_found} ->
            {:error, :not_found}
        end

      :not_found ->
        {:error, :not_found}
    end
  end

  @doc """
  Looks up the payment_id for a FireBird payment_hash binary.

  Used by Bridge to translate FireBird events to application events.
  """
  @spec lookup_payment_id(binary()) :: String.t() | nil
  def lookup_payment_id(fb_payment_hash) when is_binary(fb_payment_hash) do
    case :ets.lookup(@id_map_table, fb_payment_hash) do
      [{^fb_payment_hash, payment_id}] -> payment_id
      [] -> Base.encode16(fb_payment_hash, case: :lower)
    end
  end

  # --- Private ---

  defp submit_to_firebird(fb_payment) do
    case Process.whereis(FireBird.Executor) do
      nil ->
        # Direct execution for tests where FireBird.Supervisor isn't running.
        execute_payment_directly(fb_payment)

      _pid ->
        FireBird.Executor.submit(FireBird.Executor, fb_payment)
    end
  end

  defp execute_payment_directly(fb_payment) do
    {client_mod, client_config} = Client.client_tuple()
    executor = self()

    {:ok, in_flight} = FireBird.Payment.mark_in_flight(fb_payment)

    case :ets.whereis(@payment_table) do
      :undefined ->
        try do
          :ets.new(@payment_table, [:named_table, :set, :public, read_concurrency: true])
        rescue
          ArgumentError -> :ok
        end

      _ref ->
        :ok
    end

    :ets.insert(@payment_table, {in_flight.payment_hash, in_flight})

    Task.start(fn ->
      result =
        client_mod.pay_invoice(
          client_config,
          in_flight.bolt11,
          in_flight.amount_sats,
          in_flight.description || "",
          in_flight.fee_limit_sats
        )

      send(executor, {:direct_payment_result, in_flight.payment_hash, result})
    end)

    :ok
  end

  defp preflight_check(payment) do
    cond do
      not valid_bolt11?(payment.bolt11) ->
        {:error, :invalid_bolt11}

      not bolt11_amount_matches?(payment.bolt11, payment.amount_sats) ->
        {:error, :bolt11_amount_mismatch}

      true ->
        case acquire_flight_slot() do
          :ok ->
            case reserve_liquidity(payment.amount_sats) do
              :ok ->
                :ok

              {:error, _} = err ->
                release_flight_slot()
                err
            end

          {:error, _} = err ->
            err
        end
    end
  end

  # Atomically increment the in-flight count, rejecting if at capacity.
  defp acquire_flight_slot do
    # Atomically increment by 1, but cap at @max_concurrent.
    new_count =
      :ets.update_counter(
        @in_flight_table,
        @in_flight_count_key,
        {2, 1},
        {@in_flight_count_key, 0}
      )

    if new_count > @max_concurrent do
      :ets.update_counter(@in_flight_table, @in_flight_count_key, {2, -1})
      {:error, :too_many_concurrent}
    else
      :ok
    end
  rescue
    ArgumentError -> {:error, :too_many_concurrent}
  end

  defp bolt11_amount_matches?(bolt11, amount_sats) do
    case FireBird.Bolt11.parse_amount(bolt11) do
      {:ok, 0} -> true
      {:ok, invoice_sats} -> invoice_sats == amount_sats
      {:error, _} -> false
    end
  end

  defp valid_bolt11?(bolt11) when is_binary(bolt11) do
    # Require a minimum length that no real invoice can undercut — even the
    # shortest possible bolt11 (zero-amount, minimal fields) exceeds 50 chars.
    # This rejects trivially crafted prefix-only strings before Bolt11.parse_amount.
    byte_size(bolt11) > 50 and
      (String.starts_with?(bolt11, "lnbc") or String.starts_with?(bolt11, "lntb") or
         String.starts_with?(bolt11, "lnbcrt"))
  end

  defp valid_bolt11?(_), do: false

  defp reserve_liquidity(amount_sats) do
    case liquidity_balance() do
      :no_limit ->
        increment_in_flight_amount(amount_sats)
        :ok

      {:known, balance} ->
        reserve_with_balance_check(amount_sats, balance)
    end
  end

  defp liquidity_balance do
    case :ets.whereis(FireBird.Monitor) do
      :undefined ->
        :no_limit

      _ref ->
        {balance, status} = Monitor.get_status()
        if status == :unknown, do: :no_limit, else: {:known, balance}
    end
  end

  defp reserve_with_balance_check(amount_sats, balance) do
    current = current_in_flight()

    if current + amount_sats > balance do
      {:error, :insufficient_liquidity}
    else
      new_total = increment_in_flight_amount(amount_sats)

      if new_total > balance do
        :ets.update_counter(@in_flight_table, @in_flight_key, {2, -amount_sats})
        {:error, :insufficient_liquidity}
      else
        :ok
      end
    end
  end

  defp increment_in_flight_amount(amount_sats) do
    :ets.update_counter(@in_flight_table, @in_flight_key, {2, amount_sats}, {@in_flight_key, 0})
  end

  defp current_in_flight do
    case :ets.lookup(@in_flight_table, @in_flight_key) do
      [{_, val}] -> val
      [] -> 0
    end
  rescue
    ArgumentError -> 0
  end

  defp release_flight_slot do
    :ets.update_counter(@in_flight_table, @in_flight_count_key, {2, -1}, {@in_flight_count_key, 0})
  rescue
    ArgumentError -> :ok
  end

  defp release_liquidity(amount_sats) do
    release_flight_slot()
    :ets.update_counter(@in_flight_table, @in_flight_key, {2, -amount_sats}, {@in_flight_key, 0})
    :ok
  end

  defp store_payment(%Payment{}) do
    :ok
  end

  defp find_fb_payment_hash(payment_id) do
    case :ets.lookup(@id_map_table, {:reverse, payment_id}) do
      [{{:reverse, ^payment_id}, hash}] -> {:ok, hash}
      [] -> :not_found
    end
  rescue
    ArgumentError -> :not_found
  end

  defp merge_payment_status(payment_id, fb_payment) do
    preimage_hex =
      case fb_payment.preimage do
        nil -> nil
        bin -> Base.encode16(bin, case: :lower)
      end

    %Payment{
      id: payment_id,
      withdrawal_id: fb_payment.external_id,
      bolt11: fb_payment.bolt11,
      amount_sats: fb_payment.amount_sats,
      fee_limit_sats: nil,
      preimage: preimage_hex,
      routing_fee_sat: fb_payment.fee_sats,
      status: fb_payment.status,
      attempts: [],
      max_attempts: fb_payment.max_attempts,
      created_at: fb_payment.created_at,
      updated_at: DateTime.utc_now()
    }
  end
end
