defmodule Minted.Lightning.Payment do
  @moduledoc """
  Outbound Lightning payment aggregate with retry tracking.

  A payment transitions through the following states:

      :pending   --> :in_flight
      :in_flight --> :succeeded
      :in_flight --> :retrying   (if attempts < max_attempts)
      :in_flight --> :exhausted  (if attempts >= max_attempts)
      :retrying  --> :in_flight

  Each attempt is recorded with a timestamp and optional error.
  Exponential backoff governs delays between retries: 1s, 2s, 4s.
  """

  @enforce_keys [:id, :bolt11, :amount_sats, :status, :created_at]
  defstruct [
    :id,
    :withdrawal_id,
    :bolt11,
    :amount_sats,
    :fee_limit_sats,
    :preimage,
    :routing_fee_sat,
    status: :pending,
    attempts: [],
    max_attempts: 3,
    created_at: nil,
    updated_at: nil
  ]

  @type status :: :pending | :in_flight | :succeeded | :failed | :retrying | :exhausted

  @type attempt :: %{
          attempted_at: DateTime.t(),
          error: term() | nil
        }

  @type t :: %__MODULE__{
          id: String.t(),
          withdrawal_id: String.t() | nil,
          bolt11: String.t(),
          amount_sats: pos_integer(),
          fee_limit_sats: non_neg_integer() | nil,
          preimage: String.t() | nil,
          routing_fee_sat: non_neg_integer() | nil,
          status: status(),
          attempts: [attempt()],
          max_attempts: pos_integer(),
          created_at: DateTime.t(),
          updated_at: DateTime.t() | nil
        }

  @doc """
  Creates a new payment in `:pending` status.

  ## Options

    * `:bolt11` (required) - Lightning invoice to pay
    * `:amount_sats` (required) - amount in satoshis
    * `:withdrawal_id` - optional Cashu melt operation identifier
    * `:fee_limit_sats` - maximum routing fee (defaults to 1000)
    * `:max_attempts` - maximum retry attempts (defaults to 3)
  """
  # Maximum allowed routing fee — prevents runaway fee drain from misconfiguration.
  @max_fee_limit_sats 10_000

  @spec new(keyword()) :: t()
  def new(attrs) when is_list(attrs) do
    now = DateTime.utc_now()
    fee_limit = Keyword.get(attrs, :fee_limit_sats, 1000)
    fee_limit = max(0, min(fee_limit, @max_fee_limit_sats))

    %__MODULE__{
      id: generate_id(),
      withdrawal_id: Keyword.get(attrs, :withdrawal_id),
      bolt11: Keyword.fetch!(attrs, :bolt11),
      amount_sats: Keyword.fetch!(attrs, :amount_sats),
      fee_limit_sats: fee_limit,
      status: :pending,
      attempts: [],
      max_attempts: Keyword.get(attrs, :max_attempts, 3),
      created_at: now,
      updated_at: now
    }
  end

  @doc """
  Transitions from `:pending` or `:retrying` to `:in_flight`.
  """
  @spec mark_in_flight(t()) :: {:ok, t()} | {:error, :invalid_transition}
  def mark_in_flight(%__MODULE__{status: status} = payment)
      when status in [:pending, :retrying] do
    now = DateTime.utc_now()
    attempt = %{attempted_at: now, error: nil}

    {:ok,
     %{
       payment
       | status: :in_flight,
         attempts: payment.attempts ++ [attempt],
         updated_at: now
     }}
  end

  def mark_in_flight(%__MODULE__{}), do: {:error, :invalid_transition}

  @doc """
  Transitions from `:in_flight` to `:succeeded`, recording the preimage and routing fee.
  """
  @spec mark_succeeded(t(), String.t(), non_neg_integer()) ::
          {:ok, t()} | {:error, :invalid_transition}
  def mark_succeeded(payment, preimage, routing_fee_sat \\ 0)

  def mark_succeeded(%__MODULE__{status: :in_flight} = payment, preimage, routing_fee_sat)
      when is_binary(preimage) do
    now = DateTime.utc_now()

    {:ok,
     %{
       payment
       | status: :succeeded,
         preimage: preimage,
         routing_fee_sat: routing_fee_sat,
         updated_at: now
     }}
  end

  def mark_succeeded(%__MODULE__{}, _preimage, _fee), do: {:error, :invalid_transition}

  @doc """
  Transitions from `:in_flight` to `:retrying` or `:exhausted` based on attempt count.

  If attempts < max_attempts, transitions to `:retrying`.
  If attempts >= max_attempts, transitions to `:exhausted`.
  """
  @spec mark_failed(t(), term()) :: {:ok, t()} | {:error, :invalid_transition}
  def mark_failed(payment, error \\ nil)

  def mark_failed(%__MODULE__{status: :in_flight} = payment, error) do
    now = DateTime.utc_now()

    # Update the last attempt with the error.
    updated_attempts =
      List.update_at(payment.attempts, -1, fn attempt ->
        %{attempt | error: error}
      end)

    attempt_count = length(updated_attempts)

    new_status =
      if attempt_count >= payment.max_attempts do
        :exhausted
      else
        :retrying
      end

    {:ok,
     %{
       payment
       | status: new_status,
         attempts: updated_attempts,
         updated_at: now
     }}
  end

  def mark_failed(%__MODULE__{}, _error), do: {:error, :invalid_transition}

  @doc """
  Returns the delay in milliseconds before the next retry attempt.

  Uses exponential backoff: `2^n * 1000` where n is the 0-indexed attempt number.
  Yields 1000ms, 2000ms, 4000ms for attempts 0, 1, 2.
  """
  @spec next_retry_delay(t()) :: pos_integer()
  def next_retry_delay(%__MODULE__{attempts: attempts}) do
    n = length(attempts)
    Integer.pow(2, n) * 1000
  end

  @doc """
  Returns true if the payment can still be retried.
  """
  @spec retriable?(t()) :: boolean()
  def retriable?(%__MODULE__{status: :retrying}), do: true
  def retriable?(%__MODULE__{}), do: false

  @doc """
  Converts a Payment to a `FireBird.Payment`.

  Generates a payment_hash from the bolt11 (or random bytes) and maps
  withdrawal_id → external_id.
  """
  @spec to_firebird(t()) :: FireBird.Payment.t()
  def to_firebird(%__MODULE__{} = payment) do
    # Local tracking key — the FireBird executor uses this as its
    # ETS index. Kept as sha256(bolt11) for continuity; the REAL
    # Lightning payment hash for proof-of-payment validation is set
    # separately as `ln_payment_hash` below.
    tracking_key = :crypto.hash(:sha256, payment.bolt11)

    FireBird.Payment.new(
      payment_hash: tracking_key,
      bolt11: payment.bolt11,
      amount_sats: payment.amount_sats,
      created_at: payment.created_at,
      external_id: payment.withdrawal_id || payment.id,
      # Fee cap MUST reach phoenixd — otherwise the mint's channel
      # balance backs whatever routing fee the network settles at,
      # with no upper bound. `fee_limit_sats` on this struct is
      # already clamped in `new/1` to [0, @max_fee_limit_sats].
      fee_limit_sats: payment.fee_limit_sats,
      # The REAL 32-byte Lightning payment hash from the invoice's
      # `p` tagged field. Feeds FireBird's fail-closed preimage
      # check: mark_succeeded requires sha256(preimage) to match
      # this. Without it every "success" from phoenixd is accepted
      # unvalidated — the proof-of-payment surface is dead.
      ln_payment_hash: extract_ln_payment_hash(payment.bolt11),
      max_attempts: payment.max_attempts
    )
  end

  defp extract_ln_payment_hash(bolt11) when is_binary(bolt11) do
    case FireBird.Bolt11.payment_hash(bolt11) do
      {:ok, hash} -> hash
      # Malformed bolt11 — the payment will fail earlier on
      # preflight validation. Nil here means mark_succeeded logs a
      # warning if it ever gets called, which surfaces the
      # unreachable code path in tests.
      {:error, _reason} -> nil
    end
  end

  defp extract_ln_payment_hash(_other), do: nil

  @doc """
  Merges a FireBird.Payment result back into a Payment.

  Updates status, preimage (binary→hex), and routing fee from the FireBird payment.
  """
  @spec from_firebird(t(), FireBird.Payment.t()) :: t()
  def from_firebird(%__MODULE__{} = payment, %FireBird.Payment{} = fb_payment) do
    preimage_hex =
      case fb_payment.preimage do
        nil -> nil
        bin when is_binary(bin) -> Base.encode16(bin, case: :lower)
      end

    %{
      payment
      | status: fb_payment.status,
        preimage: preimage_hex,
        routing_fee_sat: fb_payment.fee_sats,
        updated_at: DateTime.utc_now()
    }
  end

  defp generate_id do
    Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
  end
end
