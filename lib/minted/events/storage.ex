defmodule Minted.Events.Storage do
  @moduledoc """
  Storage context events: keyset lifecycle, compaction, and recovery.
  """

  defmodule KeysetCreated do
    @moduledoc false
    @enforce_keys [:keyset_id, :timestamp]
    defstruct [:keyset_id, :timestamp]
    @type t :: %__MODULE__{keyset_id: term(), timestamp: DateTime.t()}
  end

  defmodule KeysetExpired do
    @moduledoc false
    @enforce_keys [:keyset_id, :timestamp]
    defstruct [:keyset_id, :timestamp]
    @type t :: %__MODULE__{keyset_id: term(), timestamp: DateTime.t()}
  end

  defmodule CompactionCompleted do
    @moduledoc false
    @enforce_keys [:keyset_id, :entries_removed, :elapsed_ms, :timestamp]
    defstruct [:keyset_id, :entries_removed, :elapsed_ms, :timestamp]

    @type t :: %__MODULE__{
            keyset_id: term(),
            entries_removed: non_neg_integer(),
            elapsed_ms: non_neg_integer(),
            timestamp: DateTime.t()
          }
  end

  defmodule RecoveryCompleted do
    @moduledoc false
    @enforce_keys [:report, :timestamp]
    defstruct [:report, :timestamp]
    @type t :: %__MODULE__{report: term(), timestamp: DateTime.t()}
  end

  defmodule LegacyKeyDecryptFallback do
    @moduledoc """
    Emitted when `Storage.Encryption.decrypt/2` succeeded only after
    falling back to the pre-HKDF raw-passthrough key derivation.

    A single blob still on the legacy scheme is expected during the
    migration window; sustained volume after a full boot cycle means
    something is being written un-migrated. `aad` identifies which
    AAD variant succeeded so operators can trace back to the record
    kind.
    """

    @enforce_keys [:aad, :timestamp]
    defstruct [:aad, :timestamp]

    @type t :: %__MODULE__{aad: String.t(), timestamp: DateTime.t()}
  end
end
