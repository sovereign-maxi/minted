defmodule Minted.Events.Oracle do
  @moduledoc "Oracle context domain events."

  defmodule PriceUpdated do
    @moduledoc false
    @enforce_keys [:price_usd, :sources, :timestamp]
    defstruct [:price_usd, :sources, :timestamp]
    @type t :: %__MODULE__{price_usd: float(), sources: [atom()], timestamp: DateTime.t()}
  end
end
