defmodule Minted.Events.House do
  @moduledoc """
  House-income lifecycle events.

  The mint accrues house income from fees on every mint operation
  (already published as `Minted.Events.Mint.FeesCollected`). The
  events in this module cover the OPERATOR side of that income:
  requesting a withdrawal, completing it on Lightning, or rejecting
  it (insufficient balance, half-cap violation, LN failure).

  Distinct from generic phoenixd channel operations — withdrawing
  house income is an accounting event that debits the house ledger.
  Splicing working capital is not.
  """

  defmodule WithdrawalRequested do
    @moduledoc false
    @enforce_keys [:request_id, :amount_sats, :invoice, :timestamp]
    defstruct [:request_id, :amount_sats, :invoice, :timestamp]

    @type t :: %__MODULE__{
            request_id: String.t(),
            amount_sats: pos_integer(),
            invoice: String.t(),
            timestamp: DateTime.t()
          }
  end

  defmodule WithdrawalCompleted do
    @moduledoc false
    @enforce_keys [:request_id, :amount_sats, :fee_sats, :timestamp]
    defstruct [:request_id, :amount_sats, :fee_sats, :timestamp]

    @type t :: %__MODULE__{
            request_id: String.t(),
            amount_sats: pos_integer(),
            fee_sats: non_neg_integer(),
            timestamp: DateTime.t()
          }
  end

  defmodule WithdrawalRejected do
    @moduledoc false
    @enforce_keys [:request_id, :amount_sats, :reason, :timestamp]
    defstruct [:request_id, :amount_sats, :reason, :timestamp]

    @type reason ::
            :insufficient_withdrawable
            | :half_cap_exceeded
            | :below_minimum
            | :payment_failed
            | :no_route
            | :invalid_invoice

    @type t :: %__MODULE__{
            request_id: String.t(),
            amount_sats: pos_integer(),
            reason: reason(),
            timestamp: DateTime.t()
          }
  end
end
