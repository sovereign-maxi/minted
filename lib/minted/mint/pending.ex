defmodule Minted.Mint.Pending do
  @moduledoc """
  Durable store for blind signatures awaiting client storage ACK.

  When the mint signs a deposit's blinded outputs, the signatures are
  written here keyed by `quote_id` BEFORE being pushed to the client.
  They stay until the client confirms storage via
  `wallet:tokens_stored_ok` (whereupon the entry is deleted) or until
  the reconciliation sweep classifies them as orphaned and writes a
  compensating `:tokens_burned` to balance the liability counter.

  Surviving a BEAM crash between sign and ACK is the load-bearing
  guarantee — without it a server restart would silently lose the
  signatures and leave the user with no path to recover the deposit.

  Storage is a single DETS table; volume is low (one row per
  in-flight deposit) so a hot ETS mirror would only add complexity.

  ## Session binding

  Each entry carries a stable session identifier (the browser's CSRF
  token, derived from the signed session cookie) of the LiveView
  session that initiated the deposit. `tokens_stored_ok` and
  `request_signatures` callers must present a matching session id —
  without that check, any connected wallet could complete or extract
  another user's deposit by guessing or observing a quote_id.

  The CSRF token survives LiveView reconnects and page reloads inside
  the same browser session, so an in-flight deposit can still be ACKed
  or its signatures redelivered after a transient disconnect. A
  different browser (different cookie) carries a different CSRF token
  and is correctly rejected as `session_mismatch`.
  """

  use GenServer

  require Logger

  @table __MODULE__

  # --- Public API ---

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Stores signatures for a quote. `payload` must include `:signatures`
  and `:total_amount`. The caller's `session_id` is captured so later
  ACK / redelivery requests can be authorised. An `:inserted_at`
  timestamp is added by the store.
  """
  @spec put(String.t(), String.t(), map()) :: :ok | {:error, term()}
  def put(quote_id, session_id, payload)
      when is_binary(quote_id) and is_binary(session_id) and is_map(payload) do
    GenServer.call(__MODULE__, {:put, quote_id, session_id, payload})
  end

  @doc """
  Stores an entry that survives session boundaries. Generates a
  random 32-byte recovery token, stores it alongside the payload,
  and returns it to the caller. Any subsequent `get/2` or
  `delete/2` must present the token in place of a session id.

  Use when the entry needs to be picked up by a fresh session (post-
  crash recovery, operator-driven redelivery). Prefer plain `put/3`
  with a real session_id when there is one — recovery tokens are
  bearer credentials and MUST be handled as such by the caller.
  """
  @spec put_recoverable(String.t(), map()) :: {:ok, String.t()} | {:error, term()}
  def put_recoverable(quote_id, payload) when is_binary(quote_id) and is_map(payload) do
    token = Base.encode16(:crypto.strong_rand_bytes(32), case: :lower)
    GenServer.call(__MODULE__, {:put_recoverable, quote_id, token, payload})
  end

  @doc """
  Returns the entry for `quote_id` if the requesting credential matches
  the stored session id OR the stored recovery token. If both are nil,
  no credential matches — the entry is operator-recoverable only.
  """
  @spec get(String.t(), String.t()) ::
          {:ok, map()} | :not_found | {:error, :session_mismatch}
  def get(quote_id, credential) when is_binary(quote_id) and is_binary(credential) do
    case raw_lookup(quote_id) do
      {:ok, payload} ->
        if authorised?(payload, credential), do: {:ok, payload}, else: {:error, :session_mismatch}

      :not_found ->
        :not_found
    end
  end

  @doc "Unauthenticated lookup. For internal callers (Reconciler) only."
  @spec raw_lookup(String.t()) :: {:ok, map()} | :not_found
  def raw_lookup(quote_id) when is_binary(quote_id) do
    case :dets.lookup(@table, quote_id) do
      [{^quote_id, payload}] -> {:ok, payload}
      [] -> :not_found
    end
  rescue
    ArgumentError -> :not_found
  end

  @doc """
  Deletes the entry for `quote_id` if `session_id` matches (or the
  stored session_id is nil). Returns `:ok` on success, `:not_found`
  if no entry exists, or `{:error, :session_mismatch}` if a different
  session owns it.
  """
  @spec delete(String.t(), String.t()) ::
          :ok | :not_found | {:error, :session_mismatch}
  def delete(quote_id, credential) when is_binary(quote_id) and is_binary(credential) do
    GenServer.call(__MODULE__, {:delete, quote_id, credential})
  end

  @doc """
  Force-deletes an entry without session check. For the Reconciler
  and for operator iex use only — never call from a user-driven path.
  """
  @spec force_delete(String.t()) :: :ok
  def force_delete(quote_id) when is_binary(quote_id) do
    GenServer.call(__MODULE__, {:force_delete, quote_id})
  end

  @doc """
  Returns `[{quote_id, payload}]` for entries whose `:inserted_at`
  is older than `cutoff_ms`. Used by the reconciliation sweep.
  """
  @spec expired_before(integer()) :: [{String.t(), map()}]
  def expired_before(cutoff_ms) when is_integer(cutoff_ms) do
    :dets.foldl(
      fn {qid, payload}, acc ->
        case Map.get(payload, :inserted_at) do
          ts when is_integer(ts) and ts < cutoff_ms -> [{qid, payload} | acc]
          _ -> acc
        end
      end,
      [],
      @table
    )
  rescue
    ArgumentError -> []
  end

  @spec count() :: non_neg_integer()
  def count do
    :dets.info(@table, :size) || 0
  rescue
    ArgumentError -> 0
  end

  # --- GenServer ---

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    path =
      Keyword.get_lazy(opts, :path, fn ->
        Minted.Storage.Facade.mint_pending_path()
      end)

    File.mkdir_p!(Path.dirname(path))

    case :dets.open_file(@table,
           file: String.to_charlist(path),
           type: :set,
           auto_save: 1000
         ) do
      {:ok, _ref} ->
        {:ok, %{path: path}}

      {:error, reason} ->
        Logger.error("Pending: DETS open failed path=#{path} reason=#{inspect(reason)}")
        {:stop, {:dets_open_failed, reason}}
    end
  end

  @impl true
  def handle_call({:put, quote_id, session_id, payload}, _from, state) do
    enriched =
      payload
      |> Map.put_new(:inserted_at, System.system_time(:millisecond))
      |> Map.put(:session_id, session_id)

    insert_and_sync(quote_id, enriched, :ok, state)
  end

  def handle_call({:put_recoverable, quote_id, token, payload}, _from, state) do
    enriched =
      payload
      |> Map.put_new(:inserted_at, System.system_time(:millisecond))
      |> Map.put(:recovery_token, token)
      # session_id explicitly nil so cross-session lookups can't
      # match on the missing field — only :recovery_token opens the
      # entry.
      |> Map.put(:session_id, nil)

    insert_and_sync(quote_id, enriched, {:ok, token}, state)
  end

  def handle_call({:delete, quote_id, credential}, _from, state) do
    case raw_lookup(quote_id) do
      {:ok, payload} ->
        if authorised?(payload, credential) do
          :dets.delete(@table, quote_id)
          {:reply, :ok, state}
        else
          {:reply, {:error, :session_mismatch}, state}
        end

      :not_found ->
        {:reply, :not_found, state}
    end
  end

  def handle_call({:force_delete, quote_id}, _from, state) do
    :dets.delete(@table, quote_id)
    {:reply, :ok, state}
  end

  # Sync-on-insert matches the load-bearing "surviving a BEAM crash"
  # guarantee in the moduledoc. `auto_save: 1000` (used previously)
  # lost up to ~1s of signed deposits on a VM crash — a durability
  # gap for entries the mint has already produced signatures for.
  # `:dets.sync/1` after each write costs a fsync but the write rate
  # here is bounded by user deposits, not throughput-critical.
  defp insert_and_sync(quote_id, enriched, ok_reply, state) do
    with :ok <- :dets.insert(@table, {quote_id, enriched}),
         :ok <- :dets.sync(@table) do
      {:reply, ok_reply, state}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def terminate(_reason, _state) do
    :dets.sync(@table)
    :dets.close(@table)
    :ok
  rescue
    _ -> :ok
  end

  # A caller is authorised for a Pending entry if their credential
  # matches EITHER the stored session_id OR the stored recovery
  # token. Nil session_id + nil recovery_token means "no bearer
  # exists" and no credential matches — the previous "nil = any
  # session" fallthrough is gone.
  defp authorised?(payload, credential) when is_binary(credential) do
    session_id = Map.get(payload, :session_id)
    token = Map.get(payload, :recovery_token)

    (is_binary(session_id) and Plug.Crypto.secure_compare(session_id, credential)) or
      (is_binary(token) and Plug.Crypto.secure_compare(token, credential))
  end
end
