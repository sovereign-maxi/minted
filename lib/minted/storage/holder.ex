defmodule Minted.Storage.Holder do
  @moduledoc """
  Owner of shared ETS tables that must outlive individual writer processes.

  The tables are created as `:protected` — only this GenServer can write to
  them, though any process may read. This prevents arbitrary BEAM processes
  (third-party deps, future refactors, malicious code paths) from inserting
  or mutating entries in the keyset store, which holds decrypted private key
  material at runtime.

  Writers (Store, Rebuilder) must route inserts through `write/1`. Reads
  continue to use direct `:ets.lookup/2` for hot-path performance.
  """

  use GenServer

  require Logger

  @tables [
    {Minted.Storage.Keysets.Store, [:set, :named_table, :protected, read_concurrency: true]}
  ]

  # --- Public API ---

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Inserts one or more `{key, value}` tuples into a protected ETS table owned
  by the Holder. Synchronous — returns `:ok` once the insert has completed.

  Raises if the table is not one of the Holder-owned tables.
  """
  @spec write(atom(), tuple() | [tuple()]) :: :ok
  def write(table, entries) do
    GenServer.call(__MODULE__, {:write, table, entries})
  end

  @doc """
  Deletes an entry from a protected ETS table. Synchronous.
  """
  @spec delete(atom(), term()) :: :ok
  def delete(table, key) do
    GenServer.call(__MODULE__, {:delete, table, key})
  end

  @doc """
  Clears all entries from a protected ETS table. Synchronous. Intended
  for test setup / teardown via `Minted.TestHelpers.StateHelpers.clean_state`.
  """
  @spec delete_all_objects(atom()) :: :ok
  def delete_all_objects(table) do
    GenServer.call(__MODULE__, {:delete_all_objects, table})
  end

  # --- GenServer Callbacks ---

  @impl true
  def init(_opts) do
    Enum.each(@tables, fn {name, options} ->
      case :ets.whereis(name) do
        :undefined ->
          :ets.new(name, options)

        _ref ->
          Logger.debug("Holder: table #{name} already exists, skipping creation")
      end
    end)

    owned = MapSet.new(@tables, fn {name, _opts} -> name end)

    {:ok, %{owned: owned}}
  end

  @impl true
  def handle_call({:write, table, entries}, _from, %{owned: owned} = state) do
    unless MapSet.member?(owned, table) do
      raise ArgumentError, "Holder: table #{inspect(table)} is not Holder-owned"
    end

    :ets.insert(table, entries)
    {:reply, :ok, state}
  end

  def handle_call({:delete, table, key}, _from, %{owned: owned} = state) do
    unless MapSet.member?(owned, table) do
      raise ArgumentError, "Holder: table #{inspect(table)} is not Holder-owned"
    end

    :ets.delete(table, key)
    {:reply, :ok, state}
  end

  def handle_call({:delete_all_objects, table}, _from, %{owned: owned} = state) do
    unless MapSet.member?(owned, table) do
      raise ArgumentError, "Holder: table #{inspect(table)} is not Holder-owned"
    end

    :ets.delete_all_objects(table)
    {:reply, :ok, state}
  end

  @impl true
  def handle_info(msg, state) do
    Logger.debug("Holder: Unhandled message: #{inspect(msg)}")
    {:noreply, state}
  end
end
