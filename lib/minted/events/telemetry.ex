defmodule Minted.Events.Telemetry do
  @moduledoc """
  Telemetry context events: Tor health, system status, and alerts.
  """

  defmodule TorDown do
    @moduledoc false
    @enforce_keys [:timestamp]
    defstruct [:reason, :timestamp]
    @type t :: %__MODULE__{reason: String.t() | nil, timestamp: DateTime.t()}
  end

  defmodule TorDegraded do
    @moduledoc false
    @enforce_keys [:timestamp]
    defstruct [:reason, :timestamp]
    @type t :: %__MODULE__{reason: String.t() | nil, timestamp: DateTime.t()}
  end

  defmodule TorRecovered do
    @moduledoc false
    @enforce_keys [:timestamp]
    defstruct [:timestamp]
    @type t :: %__MODULE__{timestamp: DateTime.t()}
  end

  defmodule SystemStatusChanged do
    @moduledoc false
    @enforce_keys [:status, :timestamp]
    defstruct [:status, :timestamp]
    @type t :: %__MODULE__{status: atom(), timestamp: DateTime.t()}
  end

  defmodule AlertFired do
    @moduledoc false
    @enforce_keys [:name, :domain, :severity, :reason, :timestamp]
    defstruct [:name, :domain, :severity, :reason, :timestamp]

    @type t :: %__MODULE__{
            name: atom(),
            domain: String.t(),
            severity: atom(),
            reason: String.t(),
            timestamp: DateTime.t()
          }
  end

  defmodule AlertResolved do
    @moduledoc false
    @enforce_keys [:name, :domain, :timestamp]
    defstruct [:name, :domain, :detail, :timestamp]
    @type t :: %__MODULE__{name: atom(), domain: String.t(), detail: String.t() | nil, timestamp: DateTime.t()}
  end

  defmodule KeysetRotated do
    @moduledoc false
    @enforce_keys [:old_keyset_id, :new_keyset_id, :timestamp]
    defstruct [:old_keyset_id, :new_keyset_id, :timestamp]

    @type t :: %__MODULE__{
            old_keyset_id: String.t(),
            new_keyset_id: String.t(),
            timestamp: DateTime.t()
          }
  end
end
