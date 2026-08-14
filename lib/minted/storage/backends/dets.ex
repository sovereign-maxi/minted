defmodule Minted.Storage.Backends.DETS do
  @moduledoc """
  Storage backend for the spent set cold tier using Erlang DETS.

  DETS provides file-based persistence with O(1) key lookups using `:set` type
  tables. The file path is configurable via application config or init options.

  All functions accept an explicit table reference as the first parameter
  for process safety — no process dictionary usage.

  ## Limitations

  **WARNING**: DETS has a hard 2GB file size limit. Monitor the file size in
  production using `file_size/1` and plan migration to `Backends.CubDB`
  before approaching this limit.

  ## Configuration

  Path is derived from `:data_dir` application config.
  Callers may override via the `:path` init option.
  """

  alias Minted.Storage.Paths

  @behaviour Minted.Storage.Backends.Spent

  @dets_limit_bytes 2_000_000_000

  @doc """
  Opens or creates the DETS table. Returns `{:ok, table_ref}` or `{:error, reason}`.
  """
  @impl true
  @spec init(keyword()) :: {:ok, atom()} | {:error, term()}
  def init(opts \\ []) do
    path =
      Keyword.get_lazy(opts, :path, fn ->
        Paths.mint_spent_set_dets()
      end)

    table_name = Keyword.get(opts, :table_name, :minted_spent_set)
    path_charlist = String.to_charlist(path)

    dir = Path.dirname(path)
    File.mkdir_p!(dir)

    case :dets.open_file(table_name, file: path_charlist, type: :set, auto_save: 30_000) do
      {:ok, ref} ->
        # Verify the table is readable — DETS can open corrupted files without error.
        case :dets.info(ref, :size) do
          :undefined ->
            :dets.close(ref)
            {:error, {:dets_open_failed, :corrupt_or_unreadable}}

          _size ->
            {:ok, ref}
        end

      {:error, reason} ->
        {:error, {:dets_open_failed, reason}}
    end
  end

  @doc """
  Inserts a key-value pair into the given DETS table.
  """
  @impl true
  @spec put(atom(), term(), term()) :: :ok | {:error, term()}
  def put(table, key, value) do
    case :dets.insert(table, {key, value}) do
      :ok -> :ok
      {:error, reason} -> {:error, {:dets_insert_failed, reason}}
    end
  end

  @doc """
  Inserts a key-value pair and immediately syncs to disk.
  """
  @spec put_sync(atom(), term(), term()) :: :ok | {:error, term()}
  def put_sync(table, key, value) do
    with :ok <- put(table, key, value) do
      :dets.sync(table)
    end
  end

  @doc """
  Inserts multiple `{key, value}` entries and syncs once after all inserts.
  """
  @impl true
  @spec put_batch_sync(atom(), [{term(), term()}]) :: :ok | {:error, term()}
  def put_batch_sync(table, entries) do
    results =
      Enum.map(entries, fn {key, value} ->
        put(table, key, value)
      end)

    case Enum.find(results, &match?({:error, _}, &1)) do
      nil -> :dets.sync(table)
      error -> error
    end
  end

  @doc """
  Looks up a key in the given DETS table.
  """
  @impl true
  @spec get(atom(), term()) :: {:ok, term()} | :not_found | {:error, term()}
  def get(table, key) do
    case :dets.lookup(table, key) do
      [{^key, value}] -> {:ok, value}
      [] -> :not_found
      {:error, reason} -> {:error, {:dets_lookup_failed, reason}}
    end
  end

  @doc """
  Returns true if the key exists in the given DETS table.
  """
  @impl true
  @spec member?(atom(), term()) :: boolean()
  def member?(table, key) do
    :dets.member(table, key)
  end

  @doc """
  Returns the number of entries in the given DETS table.
  """
  @impl true
  @spec size(atom()) :: non_neg_integer()
  def size(table) do
    :dets.info(table, :size) || 0
  end

  @doc """
  Loads all entries from the DETS table, returning them as a list of
  `{key, value}` tuples. Used during startup to populate ETS.
  """
  @impl true
  @spec load_all(atom()) :: [{term(), term()}]
  def load_all(table) do
    :dets.foldl(fn entry, acc -> [entry | acc] end, [], table)
  end

  @doc """
  Deletes all entries whose value matches `{keyset_id, _timestamp}`.
  Returns the number of entries removed.
  """
  @impl true
  @spec delete_match(atom(), binary()) :: non_neg_integer()
  def delete_match(table, keyset_id) do
    before = :dets.info(table, :size) || 0

    with :ok <- :dets.match_delete(table, {:_, {keyset_id, :_}}),
         :ok <- :dets.sync(table) do
      after_count = :dets.info(table, :size) || 0
      max(before - after_count, 0)
    end
  rescue
    e -> {:error, e}
  end

  @doc """
  Syncs and closes the given DETS table.
  """
  @impl true
  @spec close(atom()) :: :ok | {:error, term()}
  def close(table) do
    :dets.sync(table)

    case :dets.close(table) do
      :ok -> :ok
      {:error, reason} -> {:error, {:dets_close_failed, reason}}
    end
  end

  # --- DETS-specific helpers (not part of Backend behaviour) ---

  @doc """
  Returns the current DETS file size in bytes.

  Use this to monitor proximity to the 2GB DETS limit.
  Returns `{:ok, bytes}` or `{:error, reason}`.
  """
  @spec file_size(atom()) :: {:ok, non_neg_integer()} | {:error, term()}
  def file_size(table) do
    case :dets.info(table, :filename) do
      :undefined ->
        {:error, :table_not_open}

      filename ->
        path = List.to_string(filename)

        case File.stat(path) do
          {:ok, %{size: size}} -> {:ok, size}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  @doc """
  Returns true if the DETS file size is above 90% of the 2GB limit.
  """
  @spec near_limit?(atom()) :: boolean()
  def near_limit?(table) do
    case file_size(table) do
      {:ok, size} -> size > @dets_limit_bytes * 0.9
      _ -> false
    end
  end
end
