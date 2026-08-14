defmodule Minted.Storage.Backends.Spent do
  @moduledoc """
  Behaviour defining the storage engine contract for the spent set cold tier.

  The spent set tracks which eCash proofs have been redeemed, preventing
  double-spending. This behaviour abstracts the underlying storage engine
  so it can be swapped without modifying upstream code.

  ## Implementations

  - `Minted.Storage.Backends.DETS` — Erlang DETS for file-based
    persistence. Has a hard 2GB file size limit. Kept for reference/migration.

  - `Minted.Storage.Backends.CubDB` — Pure Elixir B-tree with ACID
    transactions, built-in compaction, and no size limit. Default backend.

  The active backend is resolved via:

      Application.get_env(:minted, :spent_set_backend, Minted.Storage.Backends.CubDB)
  """

  @type ref :: term()
  @type key :: term()
  @type value :: term()
  @type opts :: keyword()

  @doc """
  Initializes the backend with the given options.

  Returns `{:ok, ref}` where ref is a handle passed to all subsequent calls,
  or `{:error, reason}`.
  """
  @callback init(opts()) :: {:ok, ref()} | {:error, term()}

  @doc """
  Stores a key-value pair in the backend.
  """
  @callback put(ref(), key(), value()) :: :ok | {:error, term()}

  @doc """
  Inserts multiple `{key, value}` entries atomically and syncs to disk.
  """
  @callback put_batch_sync(ref(), [{key(), value()}]) :: :ok | {:error, term()}

  @doc """
  Retrieves the value associated with the given key.

  Returns `{:ok, value}` if found, `:not_found` if the key does not exist,
  or `{:error, reason}` on failure.
  """
  @callback get(ref(), key()) :: {:ok, value()} | :not_found | {:error, term()}

  @doc """
  Checks whether a key exists in the backend.

  This is the hot-path operation used during proof verification to detect
  double-spend attempts.
  """
  @callback member?(ref(), key()) :: boolean()

  @doc """
  Returns the number of entries stored in the backend.
  """
  @callback size(ref()) :: non_neg_integer()

  @doc """
  Loads all entries from the backend as a list of `{key, value}` tuples.
  Used during startup to populate ETS.
  """
  @callback load_all(ref()) :: [{key(), value()}]

  @doc """
  Deletes all entries whose value matches `{keyset_id, _timestamp}`.
  Returns the number of entries removed, or `{:error, reason}` —
  callers must not treat a failed delete as a zero-count success.
  """
  @callback delete_match(ref(), keyset_id :: binary()) :: non_neg_integer() | {:error, term()}

  @doc """
  Gracefully shuts down the backend, flushing any pending writes
  and closing file handles.
  """
  @callback close(ref()) :: :ok | {:error, term()}
end
