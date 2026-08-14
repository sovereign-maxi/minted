defmodule Minted.Storage.Supervisor do
  @moduledoc false

  use Supervisor

  alias Minted.Storage.Paths

  def start_link(init_arg) do
    Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    wal_dir = Paths.storage_wal()

    # Init the Facade's seq counter for concurrent WAL writers.
    # Per-domain Stores hold their own seq counter in state.
    # Recovery restores both from max observed seq after replay.
    :ok = Minted.Storage.Facade.init_seq_ref()

    children = [
      Minted.Storage.Holder,
      {Locker.WAL,
       [
         name: Minted.Storage.WAL,
         wal_dir: wal_dir,
         types: Minted.Storage.WAL.type_map()
       ]},
      # Liability and fee counters live in Storage so they're available
      # during WAL recovery (before Reserves.Supervisor starts).
      Supervisor.child_spec(
        {Locker.Counter,
         name: Minted.Reserves.LiabilityCounter,
         keys: [:total_minted, :total_burned],
         data_dir: Paths.reserves(),
         dets_file: Paths.reserves_liability()},
        id: Minted.Reserves.LiabilityCounter
      ),
      Supervisor.child_spec(
        {Locker.Counter,
         name: Minted.Reserves.FeeCounter,
         keys: [:total_fees_collected, :total_fee_events, :total_house_withdrawn],
         data_dir: Paths.reserves(),
         dets_file: Paths.reserves_fees()},
        id: Minted.Reserves.FeeCounter
      ),
      # Recovery runs synchronously in Runner.init/1 — the supervisor
      # blocks here until the WAL has replayed and the blocked-hashes
      # file has been written. Nothing after this line starts until
      # recovery is complete, which under the top supervisor's
      # rest_for_one strategy also gates Mint.Supervisor / Spent.
      Minted.Storage.Runner,
      {Minted.Storage.Keysets.Store, keyset_store_opts()},
      {Minted.Storage.Handler, []}
    ]

    # Customize child specs for appropriate shutdown timeouts.
    children =
      Enum.map(children, fn
        {Locker.WAL, opts} ->
          Supervisor.child_spec({Locker.WAL, opts}, shutdown: 10_000)

        child ->
          child
      end)

    Supervisor.init(children, strategy: :rest_for_one, max_restarts: 3, max_seconds: 5)
  end

  defp keyset_store_opts do
    []
  end
end
