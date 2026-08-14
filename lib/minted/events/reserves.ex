defmodule Minted.Events.Reserves do
  @moduledoc """
  Reserves context events: proof generation and deficit detection.
  """

  defmodule ProofGenerated do
    @moduledoc """
    A reserve proof was generated and published.

    Fires every proof generation interval (~10 minutes).
    """
    @enforce_keys [:proof_id, :ratio, :status, :timestamp]
    defstruct [:proof_id, :ratio, :status, :timestamp]

    @type t :: %__MODULE__{
            proof_id: term(),
            ratio: number() | :infinity,
            status: atom(),
            timestamp: DateTime.t()
          }
  end

  defmodule ReserveDeficit do
    @moduledoc false
    @enforce_keys [:ratio, :deficit_sats, :previous_status, :timestamp]
    defstruct [:ratio, :deficit_sats, :previous_status, :timestamp]

    @type t :: %__MODULE__{
            ratio: number(),
            deficit_sats: non_neg_integer(),
            previous_status: atom(),
            timestamp: DateTime.t()
          }
  end

  defmodule ReserveCriticalDeficit do
    @moduledoc false
    @enforce_keys [:ratio, :deficit_sats, :previous_status, :timestamp]
    defstruct [:ratio, :deficit_sats, :previous_status, :timestamp]

    @type t :: %__MODULE__{
            ratio: number(),
            deficit_sats: non_neg_integer(),
            previous_status: atom(),
            timestamp: DateTime.t()
          }
  end

  defmodule ReserveRecovered do
    @moduledoc false
    @enforce_keys [:ratio, :previous_status, :timestamp]
    defstruct [:ratio, :previous_status, :timestamp]

    @type t :: %__MODULE__{
            ratio: number(),
            previous_status: atom(),
            timestamp: DateTime.t()
          }
  end
end
