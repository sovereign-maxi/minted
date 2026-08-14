defmodule Minted.Storage.Backends.CubDB do
  @moduledoc """
  Storage backend for the spent set cold tier using CubDB.

  CubDB is a pure Elixir embedded key-value store backed by an immutable
  B-tree. It provides ACID transactions, built-in compaction, and has no
  file size limit — eliminating the 2GB ceiling of the DETS backend.

  ## Configuration

  Path is derived from `:data_dir` application config.
  Callers may override via the `:path` init option.
  """

  require Logger

  alias Minted.Storage.Paths

  @behaviour Minted.Storage.Backends.Spent

  @impl true
  def init(opts) do
    data_dir = Keyword.get(opts, :data_dir, Paths.mint_spent_set())

    File.mkdir_p!(data_dir)
    _ = File.chmod(data_dir, 0o700)

    CubDB.start_link(
      data_dir: data_dir,
      auto_compact: true,
      auto_file_sync: true,
      name: Keyword.get(opts, :name)
    )
  end

  @impl true
  def put(db, key, value) do
    CubDB.put(db, key, value)
  rescue
    e ->
      Logger.error("CubDB: operation crashed", crash_reason: {e, __STACKTRACE__})
      {:error, :cubdb_error}
  end

  @impl true
  def put_batch_sync(db, entries) do
    CubDB.put_multi(db, Map.new(entries))
  rescue
    e ->
      Logger.error("CubDB: operation crashed", crash_reason: {e, __STACKTRACE__})
      {:error, :cubdb_error}
  end

  @impl true
  def get(db, key) do
    case CubDB.get(db, key) do
      nil -> :not_found
      value -> {:ok, value}
    end
  end

  @impl true
  def member?(db, key), do: CubDB.has_key?(db, key)

  @impl true
  def size(db), do: CubDB.size(db)

  @impl true
  def load_all(db) do
    CubDB.select(db) |> Enum.to_list()
  end

  @impl true
  def delete_match(db, keyset_id) do
    keys =
      CubDB.select(db)
      |> Stream.filter(fn {_key, {kid, _ts}} -> kid == keyset_id end)
      |> Enum.map(&elem(&1, 0))

    CubDB.delete_multi(db, keys)
    length(keys)
  rescue
    e ->
      Logger.error("CubDB: delete_match failed: #{inspect(e)}")
      {:error, e}
  end

  @impl true
  def close(db) do
    if Process.alive?(db), do: GenServer.stop(db, :normal)
    :ok
  end
end
