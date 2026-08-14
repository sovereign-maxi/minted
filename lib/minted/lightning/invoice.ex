defmodule Minted.Lightning.Invoice do
  @moduledoc """
  Lightning invoice aggregate with a payment lifecycle state machine.

  An invoice transitions through the following states:

      :pending --> :paid
      :pending --> :expired

  Transitions are enforced — only valid transitions are allowed.
  `mark_paid/2` is idempotent when called with the same preimage.
  """

  @enforce_keys [:payment_hash, :bolt11, :amount_sats, :status, :created_at, :expires_at]
  defstruct [
    :payment_hash,
    :bolt11,
    :amount_sats,
    :quote_id,
    :status,
    :preimage,
    :created_at,
    :updated_at,
    :paid_at,
    :expires_at
  ]

  @type status :: :pending | :paid | :expired

  @type t :: %__MODULE__{
          payment_hash: String.t(),
          bolt11: String.t(),
          amount_sats: pos_integer(),
          quote_id: String.t() | nil,
          status: status(),
          preimage: String.t() | nil,
          created_at: DateTime.t(),
          updated_at: DateTime.t(),
          paid_at: DateTime.t() | nil,
          expires_at: DateTime.t()
        }

  @default_ttl_seconds 3600

  @doc """
  Creates a new invoice in `:pending` status.

  ## Options

    * `:payment_hash` (required) - SHA256 hash of the preimage
    * `:bolt11` (required) - serialized Lightning invoice
    * `:amount_sats` (required) - amount in satoshis
    * `:quote_id` - optional Cashu quote identifier
    * `:ttl_seconds` - time-to-live, defaults to 3600 (1 hour)
  """
  @spec new(keyword()) :: t()
  def new(attrs) when is_list(attrs) do
    now = DateTime.utc_now()
    ttl = Keyword.get(attrs, :ttl_seconds, @default_ttl_seconds)

    %__MODULE__{
      payment_hash: Keyword.fetch!(attrs, :payment_hash),
      bolt11: Keyword.fetch!(attrs, :bolt11),
      amount_sats: Keyword.fetch!(attrs, :amount_sats),
      quote_id: Keyword.get(attrs, :quote_id),
      status: :pending,
      preimage: nil,
      created_at: now,
      updated_at: now,
      paid_at: nil,
      expires_at: DateTime.add(now, ttl, :second)
    }
  end

  @doc """
  Transitions an invoice from `:pending` to `:paid`.

  Idempotent when called with the same preimage on an already-paid invoice.
  Returns `{:error, :invoice_expired}` if the invoice is expired.
  """
  @spec mark_paid(t(), String.t()) :: {:ok, t()} | {:already_paid, t()} | {:error, atom()}
  def mark_paid(%__MODULE__{status: :pending} = invoice, preimage) when is_binary(preimage) do
    # Verify SHA256(preimage) == payment_hash before accepting (H13)
    # Phoenixd returns preimage as hex-encoded string — decode to bytes before hashing.
    case Base.decode16(preimage, case: :mixed) do
      {:ok, preimage_bytes} when byte_size(preimage_bytes) == 32 ->
        computed_hash = Base.encode16(:crypto.hash(:sha256, preimage_bytes), case: :lower)
        normalized_payment_hash = String.downcase(invoice.payment_hash)

        if Plug.Crypto.secure_compare(computed_hash, normalized_payment_hash) do
          now = DateTime.utc_now()

          {:ok,
           %{
             invoice
             | status: :paid,
               preimage: preimage,
               paid_at: now,
               updated_at: now
           }}
        else
          {:error, :preimage_mismatch}
        end

      {:ok, _wrong_length} ->
        {:error, :preimage_mismatch}

      :error ->
        {:error, :preimage_mismatch}
    end
  end

  def mark_paid(%__MODULE__{status: :paid, preimage: preimage} = invoice, preimage) do
    {:already_paid, invoice}
  end

  def mark_paid(%__MODULE__{status: :paid}, _preimage) do
    {:error, :preimage_mismatch}
  end

  def mark_paid(%__MODULE__{status: :expired}, _preimage) do
    {:error, :invoice_expired}
  end

  @doc """
  Transitions an invoice from `:pending` to `:expired`.

  Returns `{:error, :already_paid}` if the invoice has been paid.
  """
  @spec mark_expired(t()) :: {:ok, t()} | {:error, atom()}
  def mark_expired(%__MODULE__{status: :pending} = invoice) do
    now = DateTime.utc_now()
    {:ok, %{invoice | status: :expired, updated_at: now}}
  end

  def mark_expired(%__MODULE__{status: :paid}) do
    {:error, :already_paid}
  end

  def mark_expired(%__MODULE__{status: :expired} = invoice) do
    {:ok, invoice}
  end

  @doc """
  Checks if the current time exceeds the invoice's `expires_at`.
  """
  @spec expired?(t()) :: boolean()
  def expired?(%__MODULE__{expires_at: expires_at}) do
    DateTime.compare(DateTime.utc_now(), expires_at) == :gt
  end

  @doc """
  Converts an Invoice to a `FireBird.Invoice`.

  Translates hex payment_hash to binary and maps quote_id → external_id.
  """
  @spec to_firebird(t()) :: FireBird.Invoice.t()
  def to_firebird(%__MODULE__{} = invoice) do
    FireBird.Invoice.new(
      payment_hash: decode_hex!(invoice.payment_hash),
      bolt11: invoice.bolt11,
      amount_sats: invoice.amount_sats,
      created_at: invoice.created_at,
      expires_at: invoice.expires_at,
      external_id: invoice.quote_id
    )
  end

  @doc """
  Converts a `FireBird.Invoice` back to an Invoice.

  Translates binary payment_hash to hex and maps external_id → quote_id.
  If a `quote_id` is provided, it overrides the external_id from the
  FireBird invoice (for cases where the quote_map has the mapping).
  """
  @spec from_firebird(FireBird.Invoice.t(), keyword()) :: t()
  def from_firebird(%FireBird.Invoice{} = fb_invoice, opts \\ []) do
    now = DateTime.utc_now()
    quote_id = Keyword.get(opts, :quote_id, fb_invoice.external_id)

    preimage_hex =
      case fb_invoice.preimage do
        nil -> nil
        bin when is_binary(bin) -> Base.encode16(bin, case: :lower)
      end

    %__MODULE__{
      payment_hash: Base.encode16(fb_invoice.payment_hash, case: :lower),
      bolt11: fb_invoice.bolt11,
      amount_sats: fb_invoice.amount_sats,
      quote_id: quote_id,
      status: fb_invoice.status,
      preimage: preimage_hex,
      created_at: fb_invoice.created_at,
      updated_at: now,
      paid_at: fb_invoice.paid_at,
      expires_at: fb_invoice.expires_at
    }
  end

  defp decode_hex!(hex) when is_binary(hex) do
    case Base.decode16(hex, case: :mixed) do
      {:ok, bin} -> bin
      :error -> raise ArgumentError, "invalid hex string: #{hex}"
    end
  end
end

defimpl Inspect, for: Minted.Lightning.Invoice do
  def inspect(%Minted.Lightning.Invoice{} = invoice, opts) do
    redacted_map =
      invoice
      |> Map.from_struct()
      |> Map.update(:preimage, nil, fn
        nil -> nil
        _val -> "**REDACTED**"
      end)

    Inspect.Algebra.concat([
      "#Minted.Lightning.Invoice<",
      Inspect.Algebra.to_doc(redacted_map, opts),
      ">"
    ])
  end
end
