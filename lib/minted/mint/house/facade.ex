defmodule Minted.Mint.House.Facade do
  @moduledoc """
  Public API for the House-income bounded context.

  Every caller outside `Minted.Mint.House.*` routes through this
  module. The Store, WAL type bytes, ETS table names, and
  half-cap arithmetic are implementation details that this facade
  hides.

  ## Reads

    * `earned/0`             — cumulative fees ever collected
    * `drawn/0`              — cumulative sats withdrawn as house income
    * `withdrawable/0`       — currently withdrawable (earned - drawn - in_flight)
    * `in_flight/0`          — currently requested but not yet completed
    * `max_single_request/0` — half-cap ceiling on a single request

  ## Writes

    * `request_withdrawal/2`   — guard-checked; may return errors
    * `complete_withdrawal/2`  — after LN payment settles
    * `reject_withdrawal/2`    — for LN failures + operator cancellation

  ## Events

    Publishes `Minted.Events.House.{WithdrawalRequested,
    WithdrawalCompleted, WithdrawalRejected}` on the local EventBus
    so admin dashboards, alerters, and audit loggers can subscribe.
  """

  alias Minted.Mint.House.Store
  alias Minted.Operator.Audit

  @doc "Cumulative fees ever collected by the mint (sats)."
  @spec earned() :: non_neg_integer()
  def earned, do: Store.total_earned()

  @doc "Cumulative sats drawn out as house income."
  @spec drawn() :: non_neg_integer()
  def drawn, do: Store.total_drawn()

  @doc "Sats currently in-flight (requested but not yet completed or rejected)."
  @spec in_flight() :: non_neg_integer()
  def in_flight, do: Store.in_flight()

  @doc """
  Sats currently withdrawable. Equals `earned - drawn - in_flight`.

  Subtracts in-flight so simultaneous requests can't each independently
  see the same balance and both pass guard checks.
  """
  @spec withdrawable() :: non_neg_integer()
  def withdrawable, do: Store.withdrawable()

  @doc """
  Maximum sats permitted in a single withdrawal request.

  Enforces the half-cap security control:
  `requested_sats ≤ withdrawable / 2`

  Bounds the blast radius of a compromised admin session. Same
  pattern as PERP WALK's federation-income withdrawal rule
  (see `PerpWalk.Federation.*`).
  """
  @spec max_single_request() :: non_neg_integer()
  def max_single_request, do: Store.max_single_request()

  @doc """
  Registers a withdrawal request. Guards check `withdrawable`,
  half-cap, and minimum thresholds. On success, records the amount
  in-flight, appends the WAL entry, and publishes the event.

  Return values:
    * `{:ok, event}` — request accepted, caller now proceeds to LN payment
    * `{:error, :insufficient_withdrawable}` — amount > withdrawable
    * `{:error, :half_cap_exceeded}` — amount > withdrawable / 2
    * `{:error, :below_minimum}` — amount < configured minimum
  """
  @spec request_withdrawal(pos_integer(), String.t()) ::
          {:ok, Minted.Events.House.WithdrawalRequested.t()}
          | {:error, :insufficient_withdrawable | :half_cap_exceeded | :below_minimum}
  def request_withdrawal(amount_sats, invoice)
      when is_integer(amount_sats) and amount_sats > 0 and is_binary(invoice) do
    request_id = generate_request_id()

    case Store.register_request(request_id, amount_sats, invoice) do
      {:ok, event} ->
        Audit.record(:house_withdrawal_requested, %{request_id: request_id, amount_sats: amount_sats})
        {:ok, event}

      {:error, _} = err ->
        err
    end
  end

  @doc """
  Marks a previously-registered request as completed. Called after
  the Lightning payment settles. Increments the drawn counter.
  """
  @spec complete_withdrawal(String.t(), non_neg_integer()) :: :ok | {:error, :not_found}
  def complete_withdrawal(request_id, fee_sats \\ 0)
      when is_binary(request_id) and is_integer(fee_sats) and fee_sats >= 0 do
    case Store.complete_request(request_id, fee_sats) do
      :ok ->
        Audit.record(:house_withdrawal_completed, %{request_id: request_id, fee_sats: fee_sats})
        :ok

      {:error, _} = err ->
        err
    end
  end

  @doc """
  Marks a previously-registered request as rejected. Restores
  withdrawable capacity by dropping the amount from in-flight.
  """
  @spec reject_withdrawal(String.t(), Minted.Events.House.WithdrawalRejected.reason()) ::
          :ok | {:error, :not_found}
  def reject_withdrawal(request_id, reason)
      when is_binary(request_id) and is_atom(reason) do
    case Store.reject_request(request_id, reason) do
      :ok ->
        Audit.record(:house_withdrawal_rejected, %{request_id: request_id, reason: reason})
        :ok

      {:error, _} = err ->
        err
    end
  end

  # --- Internals ---

  # Crypto-random per-request ID. 96-bit space, base32-encoded so
  # WAL replay can identify entries by ID even across VM restarts.
  defp generate_request_id do
    :crypto.strong_rand_bytes(12) |> Base.hex_encode32(padding: false, case: :lower)
  end
end
