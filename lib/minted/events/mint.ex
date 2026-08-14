defmodule Minted.Events.Mint do
  @moduledoc """
  Mint context events: token minting, burning, swapping, and quote lifecycle.
  """

  defmodule TokensMinted do
    @moduledoc false
    @enforce_keys [:amount, :count, :timestamp]
    defstruct [:amount, :count, :timestamp]
    @type t :: %__MODULE__{amount: pos_integer(), count: pos_integer(), timestamp: DateTime.t()}
  end

  defmodule TokensBurned do
    @moduledoc false
    @enforce_keys [:amount, :count, :timestamp]
    defstruct [:amount, :count, :timestamp]
    @type t :: %__MODULE__{amount: pos_integer(), count: pos_integer(), timestamp: DateTime.t()}
  end

  defmodule TokensSwapped do
    @moduledoc false
    @enforce_keys [:amount, :count, :timestamp]
    defstruct [:amount, :count, :timestamp]
    @type t :: %__MODULE__{amount: pos_integer(), count: pos_integer(), timestamp: DateTime.t()}
  end

  defmodule QuoteCreated do
    @moduledoc false
    @enforce_keys [:quote_id, :timestamp]
    defstruct [:quote_id, :timestamp]
    @type t :: %__MODULE__{quote_id: String.t(), timestamp: DateTime.t()}
  end

  defmodule DoubleSpendDetected do
    @moduledoc false
    @enforce_keys [:secret_hash, :keyset_id, :timestamp]
    defstruct [:secret_hash, :keyset_id, :timestamp]

    @type t :: %__MODULE__{
            secret_hash: binary(),
            keyset_id: String.t(),
            timestamp: DateTime.t()
          }
  end

  defmodule QuoteUpdated do
    @moduledoc false
    @enforce_keys [:quote_id, :status, :timestamp]
    defstruct [:quote_id, :status, :timestamp]
    @type t :: %__MODULE__{quote_id: String.t(), status: atom(), timestamp: DateTime.t()}
  end

  defmodule FeesCollected do
    @moduledoc false
    @enforce_keys [:amount, :quote_id, :timestamp]
    defstruct [:amount, :quote_id, :timestamp]
    @type t :: %__MODULE__{amount: pos_integer(), quote_id: String.t(), timestamp: DateTime.t()}
  end

  defmodule OrphanDepositReconciled do
    @moduledoc """
    Emitted by `Minted.Mint.Pending.Reconciler` when an orphaned
    deposit (signed but never ACK'd by the client) is aged out and a
    compensating `:tokens_burned` is written to balance liability.
    """
    @enforce_keys [:quote_id, :amount, :timestamp]
    defstruct [:quote_id, :amount, :timestamp]
    @type t :: %__MODULE__{quote_id: String.t(), amount: pos_integer(), timestamp: DateTime.t()}
  end
end
