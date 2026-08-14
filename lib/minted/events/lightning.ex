defmodule Minted.Events.Lightning do
  @moduledoc """
  Lightning context events: invoice lifecycle, payment outcomes, and liquidity status.
  """

  defmodule InvoicePaid do
    @moduledoc false
    @enforce_keys [:payment_hash, :amount_sats, :preimage, :timestamp]
    defstruct [:payment_hash, :amount_sats, :preimage, :timestamp, :quote_id]

    @type t :: %__MODULE__{
            payment_hash: String.t(),
            amount_sats: pos_integer(),
            preimage: String.t(),
            timestamp: DateTime.t(),
            quote_id: String.t() | nil
          }
  end

  defmodule InvoiceExpired do
    @moduledoc false
    @enforce_keys [:payment_hash, :amount_sats, :timestamp]
    defstruct [:payment_hash, :amount_sats, :timestamp]

    @type t :: %__MODULE__{
            payment_hash: String.t(),
            amount_sats: pos_integer(),
            timestamp: DateTime.t()
          }
  end

  defmodule PaymentSent do
    @moduledoc false
    @enforce_keys [:payment_id, :bolt11, :amount_sats, :preimage, :timestamp]
    defstruct [:payment_id, :bolt11, :amount_sats, :preimage, :timestamp, :routing_fee_sat]

    @type t :: %__MODULE__{
            payment_id: String.t(),
            bolt11: String.t(),
            amount_sats: pos_integer(),
            preimage: String.t(),
            timestamp: DateTime.t(),
            routing_fee_sat: non_neg_integer() | nil
          }
  end

  defmodule PaymentFailed do
    @moduledoc false
    @enforce_keys [:payment_id, :error, :attempt, :timestamp]
    defstruct [:payment_id, :error, :attempt, :timestamp, :will_retry]

    @type t :: %__MODULE__{
            payment_id: String.t(),
            error: term(),
            attempt: non_neg_integer(),
            timestamp: DateTime.t(),
            will_retry: boolean() | nil
          }
  end

  defmodule PaymentExhausted do
    @moduledoc false
    @enforce_keys [:payment_id, :error, :attempts, :timestamp]
    defstruct [:payment_id, :error, :attempts, :timestamp]

    @type t :: %__MODULE__{
            payment_id: String.t(),
            error: term(),
            attempts: non_neg_integer(),
            timestamp: DateTime.t()
          }
  end

  defmodule PaymentUnknown do
    @moduledoc """
    Emitted when a payment's Lightning outcome is undetermined —
    HTTP timeout, transport error, task crash, or ambiguous 5xx from
    phoenixd. The payment MAY still settle. Callers MUST NOT release
    the reservation on this event; the quote transitions to
    `:settlement_unknown` and the operator (or a future reconciler)
    resolves it against the node.

    `phoenixd_id` is included when we captured it before the
    ambiguous event; nil when we never got a response back.
    """

    @enforce_keys [:payment_id, :error, :attempt, :timestamp]
    defstruct [:payment_id, :error, :attempt, :timestamp, :phoenixd_id]

    @type t :: %__MODULE__{
            payment_id: String.t(),
            error: term(),
            attempt: non_neg_integer(),
            timestamp: DateTime.t(),
            phoenixd_id: String.t() | nil
          }
  end

  defmodule LiquidityLow do
    @moduledoc false
    @enforce_keys [:balance_sats, :previous_status, :current_status, :timestamp]
    defstruct [:balance_sats, :previous_status, :current_status, :timestamp]

    @type t :: %__MODULE__{
            balance_sats: non_neg_integer(),
            previous_status: atom(),
            current_status: atom(),
            timestamp: DateTime.t()
          }
  end

  defmodule LiquidityCritical do
    @moduledoc false
    @enforce_keys [:balance_sats, :previous_status, :current_status, :timestamp]
    defstruct [:balance_sats, :previous_status, :current_status, :timestamp]

    @type t :: %__MODULE__{
            balance_sats: non_neg_integer(),
            previous_status: atom(),
            current_status: atom(),
            timestamp: DateTime.t()
          }
  end

  defmodule LiquidityRecovered do
    @moduledoc false
    @enforce_keys [:balance_sats, :previous_status, :current_status, :timestamp]
    defstruct [:balance_sats, :previous_status, :current_status, :timestamp]

    @type t :: %__MODULE__{
            balance_sats: non_neg_integer(),
            previous_status: atom(),
            current_status: atom(),
            timestamp: DateTime.t()
          }
  end
end
