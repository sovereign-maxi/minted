defmodule Minted.Guards do
  @moduledoc """
  Centralised operational guards for write-path entry points.

  Every operation that creates, modifies, or moves tokens must call
  `ensure_operational!/0` before proceeding. This prevents any money
  movement when the system is in a halted state (quorum lost, state
  diverged, disk critical).

  Reads directly from `persistent_term` — zero-cost when the system
  is operational (no GenServer call, no ETS lookup).
  """

  defmodule SystemHaltedError do
    @moduledoc "Raised when a write operation is attempted while the system is halted."
    defexception [:message]

    @impl true
    def exception(reason) do
      %__MODULE__{message: "system is halted: #{reason}"}
    end
  end

  @doc """
  Raises `SystemHaltedError` if the system is halted.

  Call at the top of every write-path entry point.
  """
  @spec ensure_operational!() :: :ok
  def ensure_operational! do
    case :persistent_term.get({Minted.Telemetry.Health.System, :halted}, nil) do
      {true, reason} -> raise SystemHaltedError, reason
      _ -> :ok
    end
  end

  @doc """
  Returns `true` if the system is operational (not halted).

  Use for conditional checks where raising is not appropriate
  (e.g. UI rendering, proof generation skipping).
  """
  @spec operational?() :: boolean()
  def operational? do
    :persistent_term.get({Minted.Telemetry.Health.System, :halted}, nil) == nil
  end
end
