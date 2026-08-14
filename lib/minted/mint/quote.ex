defmodule Minted.Mint.Quote do
  @moduledoc """
  Stateful aggregate governing the lifecycle of a mint or melt request.

  State machine (mint):  pending → invoiced → paid → claimed
  State machine (melt):  invoiced → paying → paid → claimed
                         paying → invoiced  (abort on failure)
  Expiry:                pending/invoiced/paying → expired
  """

  alias Minted.Mint.Token

  @enforce_keys [:id, :amount, :fee, :denomination_breakdown, :status, :created_at, :expires_at]
  defstruct [
    :id,
    :amount,
    :fee,
    :denomination_breakdown,
    :status,
    :type,
    :bolt11,
    :invoice,
    :payment_hash,
    :created_at,
    :expires_at,
    :paid_at,
    :claimed_at,
    :paying_since,
    :melt_context,
    :keyset_id,
    # Session token identifying the browser wallet that created this
    # quote (see `MintedWeb.WalletLive` — mirrors the `Mint.Pending`
    # ACK-binding pattern). `nil` when created via the /v1 API path,
    # where the PoW gate governs owner semantics instead.
    :owner_session,
    method: :bolt11
  ]

  @type status ::
          :pending
          | :invoiced
          | :paying
          | :paid
          | :claimed
          | :stale_claimed
          | :settlement_unknown
          | :expired
  @type quote_type :: :mint | :melt
  @type method :: :bolt11

  @type t :: %__MODULE__{
          id: String.t(),
          amount: pos_integer(),
          fee: non_neg_integer(),
          denomination_breakdown: [pos_integer()],
          status: status(),
          type: quote_type() | nil,
          method: method(),
          bolt11: String.t() | nil,
          invoice: String.t() | nil,
          payment_hash: String.t() | nil,
          created_at: DateTime.t(),
          expires_at: DateTime.t(),
          paid_at: DateTime.t() | nil,
          claimed_at: DateTime.t() | nil,
          paying_since: DateTime.t() | nil,
          melt_context: map() | nil,
          keyset_id: String.t() | nil,
          owner_session: String.t() | nil
        }

  # TTL must be at or below the Lightning invoice expiry (typically 3600s).
  # Configurable via [:mint, :quote_ttl] so operators can tune per-deployment.
  @quote_ttl_seconds Application.compile_env(:minted, [:mint, :quote_ttl], 3600)
  @spec new(pos_integer(), non_neg_integer(), String.t() | nil, String.t() | nil) :: t()
  def new(amount, fee \\ 0, keyset_id \\ nil, owner_session \\ nil)
      when is_integer(amount) and amount > 0 do
    now = DateTime.utc_now()

    %__MODULE__{
      id: generate_id(),
      amount: amount,
      fee: fee,
      denomination_breakdown: Token.decompose_amount(amount),
      type: :mint,
      status: :pending,
      created_at: now,
      expires_at: DateTime.add(now, @quote_ttl_seconds, :second),
      keyset_id: keyset_id,
      owner_session: owner_session
    }
  end

  @spec new_melt(pos_integer(), non_neg_integer(), String.t(), String.t() | nil) :: t()
  def new_melt(amount, fee, bolt11, owner_session \\ nil)
      when is_integer(amount) and amount > 0 and is_binary(bolt11) do
    now = DateTime.utc_now()

    %__MODULE__{
      id: generate_id(),
      amount: amount,
      fee: fee,
      denomination_breakdown: Token.decompose_amount(amount),
      type: :melt,
      bolt11: bolt11,
      invoice: bolt11,
      status: :invoiced,
      created_at: now,
      expires_at: DateTime.add(now, @quote_ttl_seconds, :second),
      owner_session: owner_session
    }
  end

  @spec attach_invoice(t(), String.t()) :: {:ok, t()} | {:error, :invalid_transition}
  def attach_invoice(%__MODULE__{status: :pending} = quote, invoice) do
    {:ok, %{quote | status: :invoiced, invoice: invoice}}
  end

  def attach_invoice(_, _), do: {:error, :invalid_transition}

  @doc "Atomically transition a melt quote from :invoiced to :paying (serialization point)."
  @spec start_payment(t()) :: {:ok, t()} | {:error, :invalid_transition}
  def start_payment(%__MODULE__{status: :invoiced} = quote) do
    {:ok, %{quote | status: :paying, paying_since: DateTime.utc_now()}}
  end

  def start_payment(_), do: {:error, :invalid_transition}

  @doc "Revert a melt quote from :paying or :settlement_unknown back to :invoiced on failure."
  @spec abort_payment(t()) :: {:ok, t()} | {:error, :invalid_transition}
  def abort_payment(%__MODULE__{status: status} = quote)
      when status in [:paying, :settlement_unknown] do
    {:ok, %{quote | status: :invoiced, paying_since: nil, melt_context: nil}}
  end

  def abort_payment(_), do: {:error, :invalid_transition}

  @doc """
  Transitions a melt quote to :settlement_unknown when payment outcome is ambiguous.

  Tokens remain reserved (not released) until the operator resolves the outcome.
  This is fail-closed: if the payment did settle, the operator commits the reservation.
  If it did not, the operator releases it.
  """
  @spec mark_settlement_unknown(t()) :: {:ok, t()} | {:error, :invalid_transition}
  def mark_settlement_unknown(%__MODULE__{status: :paying} = quote) do
    {:ok, %{quote | status: :settlement_unknown}}
  end

  def mark_settlement_unknown(_), do: {:error, :invalid_transition}

  @spec mark_paid(t(), String.t()) :: {:ok, t()} | {:error, :invalid_transition | :quote_expired}
  def mark_paid(%__MODULE__{status: status} = quote, payment_hash)
      when status in [:invoiced, :paying] and is_binary(payment_hash) do
    if expired?(quote) do
      {:error, :quote_expired}
    else
      {:ok, %{quote | status: :paid, paid_at: DateTime.utc_now(), payment_hash: payment_hash}}
    end
  end

  def mark_paid(_, _payment_hash), do: {:error, :invalid_transition}

  @spec mark_paid(t()) :: {:ok, t()} | {:error, :invalid_transition | :quote_expired}
  def mark_paid(%__MODULE__{status: status, type: :melt} = quote)
      when status in [:invoiced, :paying, :settlement_unknown] do
    if expired?(quote) and status != :settlement_unknown do
      {:error, :quote_expired}
    else
      {:ok, %{quote | status: :paid, paid_at: DateTime.utc_now()}}
    end
  end

  def mark_paid(_), do: {:error, :invalid_transition}

  @spec claim(t()) :: {:ok, t()} | {:error, :invalid_transition | :quote_expired}
  def claim(%__MODULE__{status: :paid} = quote) do
    # Late claim of an already-PAID quote is safe: the mint has
    # already received the sats. The previous expiry gate here
    # locked payers out of their own tokens if the wallet took too
    # long to redeem — a strictly worse outcome than paying for
    # tokens that turn out to be temporary. `:paid` is a terminal
    # positive; TTL only gates the pre-payment window.
    {:ok, %{quote | status: :claimed, claimed_at: DateTime.utc_now()}}
  end

  def claim(_), do: {:error, :invalid_transition}

  @doc """
  Reverts a claimed quote to :paid. ONLY safe when the WAL write failed
  BEFORE any liability was recorded or signatures were produced. If the
  WAL write succeeded, the quote must stay claimed — unclaiming after
  WAL write would allow double-mint.
  """
  @spec unclaim(t()) :: {:ok, t()} | {:error, :invalid_transition}
  def unclaim(%__MODULE__{status: :claimed} = quote) do
    {:ok, %{quote | status: :paid, claimed_at: nil}}
  end

  def unclaim(_), do: {:error, :invalid_transition}

  @doc """
  Transitions a stale `:claimed` quote to `:stale_claimed` terminal state.

  This prevents double-mint: if blind signing takes too long and the claim
  times out, the quote is permanently locked rather than returned to `:paid`.
  """
  @spec mark_stale_claimed(t()) :: {:ok, t()} | {:error, :invalid_transition}
  def mark_stale_claimed(%__MODULE__{status: :claimed} = quote) do
    {:ok, %{quote | status: :stale_claimed}}
  end

  def mark_stale_claimed(_), do: {:error, :invalid_transition}

  @spec expire(t()) :: {:ok, t()} | {:error, :invalid_transition}
  def expire(%__MODULE__{status: status} = quote)
      when status in [:pending, :invoiced] do
    {:ok, %{quote | status: :expired}}
  end

  def expire(_), do: {:error, :invalid_transition}

  @spec expired?(t()) :: boolean()
  def expired?(%__MODULE__{expires_at: expires_at}) do
    DateTime.compare(DateTime.utc_now(), expires_at) == :gt
  end

  defp generate_id do
    :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
  end
end
