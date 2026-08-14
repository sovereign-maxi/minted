defmodule Minted.Events.Identity do
  @moduledoc """
  Identity context events: rate limiting.
  """

  defmodule RateLimitEscalated do
    @moduledoc false
    @enforce_keys [:circuit_id_hash, :multiplier, :cooldown_seconds, :timestamp]
    defstruct [:circuit_id_hash, :multiplier, :cooldown_seconds, :timestamp]

    @type t :: %__MODULE__{
            circuit_id_hash: binary(),
            multiplier: number(),
            cooldown_seconds: non_neg_integer(),
            timestamp: DateTime.t()
          }
  end
end
