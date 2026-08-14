defmodule Minted.Storage.Runner do
  @moduledoc """
  Runs storage recovery synchronously during `init/1` so the supervisor
  cannot return from `start_link` until recovery is complete.

  Under the parent Application's `:rest_for_one` strategy, that means
  `Minted.Mint.Supervisor` (which brings up `Minted.Mint.Spent`) is
  never started until the WAL has been fully replayed and the
  `blocked_hashes` file has been written. Without this ordering, `Spent`
  would boot concurrently with the WAL scan, read a missing / stale
  `blocked_hashes.bin`, and leave paid-out tokens spendable for the
  entire boot.

  Recovery only needs the WAL server + `Locker.Counter` processes above
  it in `Storage.Supervisor`'s child list; those start first (also under
  `:rest_for_one`), so the synchronous init is safe.
  """

  use GenServer

  require Logger

  alias Minted.Storage.Recovery

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(_opts) do
    case Recovery.run() do
      {:ok, report} ->
        Logger.info("Runner: storage recovery completed, level=#{Map.get(report, :level, "unknown")}")

        {:ok, %{recovery: :ok}}

      {:error, {:recovery_failed, report}} ->
        Logger.error(
          "Runner: recovery failed at all levels, refusing to start, " <>
            "status=#{inspect(Map.get(report, :status))}"
        )

        # Returning `:stop` from init/1 fails the supervisor's
        # start_link cleanly. The Application supervisor's
        # `max_restarts` budget catches persistent recovery failures
        # rather than letting them re-attempt forever.
        {:stop,
         {:recovery_failed, Map.get(report, :status),
          "Storage recovery failed at all levels — refusing to start with inconsistent state"}}
    end
  end
end
