defmodule Minted.Events.Wallet do
  @moduledoc """
  Wallet context events: balance changes from deposits, sends, receives, and melts.
  """

  defmodule BalanceChanged do
    @moduledoc false
    @enforce_keys [:balance, :timestamp]
    defstruct [:balance, :timestamp]
    @type t :: %__MODULE__{balance: non_neg_integer(), timestamp: DateTime.t()}
  end
end
