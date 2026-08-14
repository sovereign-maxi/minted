defmodule Minted.Storage.Facade do
  @moduledoc false

  alias Locker.WAL.Entry
  alias Minted.Operator.Audit
  alias Minted.Storage.Backends
  alias Minted.Storage.Encryption
  alias Minted.Storage.Keysets.Store
  alias Minted.Storage.Paths
  alias Minted.Storage.Recovery

  @seq_ref_key {__MODULE__, :seq_ref}

  # --- Keysets ---

  @doc "Retrieves a keyset by ID."
  @spec get_keyset(binary()) :: {:ok, map()} | :not_found
  def get_keyset(keyset_id), do: Store.get(keyset_id)

  @doc "Returns all active keysets."
  @spec get_active_keyset() :: [map()]
  def get_active_keyset, do: Store.get_active()

  @doc "Returns every keyset (active, rotated, and expired) in the store."
  @spec list_keysets() :: [map()]
  def list_keysets, do: Store.list()

  @doc "Inserts a keyset into the store."
  @spec put_keyset(map()) :: :ok | {:error, term()}
  def put_keyset(keyset), do: Store.put(keyset)

  @doc "Rotates a keyset: marks old as rotated, inserts new."
  @spec rotate_keyset(binary(), map()) :: :ok | {:error, term()}
  def rotate_keyset(old_keyset_id, new_keyset) do
    case Store.rotate(old_keyset_id, new_keyset) do
      :ok ->
        Audit.record(:keyset_rotated, %{
          old_keyset_id: old_keyset_id,
          new_keyset_id: Map.get(new_keyset, :id)
        })

        :ok

      {:error, _} = err ->
        err
    end
  end

  @doc "Marks a keyset as expired."
  @spec expire_keyset(binary()) :: :ok | {:error, term()}
  def expire_keyset(keyset_id) do
    case Store.expire(keyset_id) do
      :ok ->
        Audit.record(:keyset_expired, %{keyset_id: keyset_id})
        :ok

      {:error, _} = err ->
        err
    end
  end

  # --- WAL ---

  @doc """
  Appends an entry to the default WAL, stamping the next seq from
  the Facade's `:atomics` counter into the payload.

  This is the entry point for concurrent writers (controllers,
  services, adapters) that don't own a domain Store. Domain Stores
  that hold their own seq counter (e.g. `Keysets.Store`) call
  `Locker.WAL.append/2` directly with the seq from their GenServer
  state — see the WAL-facade-exemption pattern.

  The Facade's counter is independent from per-Store counters. A
  recovery boot rebuilds it from the highest seq observed across the
  facade-owned WAL types via `restore_seq_ref/1`.
  """
  @spec write_wal(atom(), map()) :: :ok | {:error, term()}
  def write_wal(type, payload) when is_atom(type) and is_map(payload) do
    sealed = Map.put(payload, :seq, next_facade_seq())
    Locker.WAL.append(Minted.Storage.WAL, %Entry{type: type, payload: sealed})
  end

  @doc """
  Appends a pre-built `Locker.WAL.Entry` to the WAL via the Facade
  counter. Same semantics as `write_wal/2`; this 1-arity form exists
  for adapters that receive a pre-wrapped entry.
  """
  @spec append_wal_entry(Entry.t()) :: :ok | {:error, term()}
  def append_wal_entry(%Entry{type: type, payload: payload}) when is_map(payload) do
    write_wal(type, payload)
  end

  @doc """
  Returns the next sequence number for facade-mediated WAL writes.
  Lock-free `:atomics.add_get/3` so concurrent callers (controllers,
  services) get a strictly increasing global ordering across all
  facade-owned types.
  """
  @spec next_facade_seq() :: pos_integer()
  def next_facade_seq, do: :atomics.add_get(seq_ref(), 1, 1)

  @doc """
  Initialises the Facade's seq counter at zero. Idempotent — safe to
  call from `Storage.Supervisor` boot before any writer.
  """
  @spec init_seq_ref() :: :ok
  def init_seq_ref do
    case :persistent_term.get(@seq_ref_key, nil) do
      nil ->
        ref = :atomics.new(1, signed: false)
        :persistent_term.put(@seq_ref_key, ref)
        :ok

      _existing ->
        :ok
    end
  end

  @doc """
  Restores the Facade counter so the next allocation returns
  `max_seq + 1`. Called by `Storage.Recovery` after WAL replay with
  the highest seq observed across the facade-owned types.
  """
  @spec restore_seq_ref(non_neg_integer()) :: :ok
  def restore_seq_ref(max_seq) when is_integer(max_seq) and max_seq >= 0 do
    :atomics.put(seq_ref(), 1, max_seq)
  end

  @doc "Current facade seq counter without incrementing. Operator visibility only."
  @spec current_facade_seq() :: non_neg_integer()
  def current_facade_seq, do: :atomics.get(seq_ref(), 1)

  defp seq_ref do
    case :persistent_term.get(@seq_ref_key, nil) do
      nil ->
        init_seq_ref()
        :persistent_term.get(@seq_ref_key)

      ref ->
        ref
    end
  end

  @doc "Reads all WAL entries currently on disk."
  @spec read_all_wal() :: {:ok, [Entry.t()]} | {:error, term()}
  def read_all_wal do
    Locker.WAL.read_all(Minted.Storage.WAL)
  end

  # --- Spent-set backend ---

  @doc """
  Opens the configured persistent backend for the Mint spent set. On
  success returns `{:ok, {backend_module, backend_ref}}`; on failure
  returns `{:error, {module(), reason}}` so the caller can decide
  whether to fall back to an in-memory mode or halt. Centralising
  backend choice here keeps Mint.Spent from having to name the
  concrete Backends.CubDB / Backends.DETS modules directly.
  """
  @spec open_spent_set_backend() :: {:ok, {module(), term()}} | {:error, {module(), term()}}
  def open_spent_set_backend do
    backend_mod = Application.get_env(:minted, :spent_set_backend, Backends.CubDB)
    opts = spent_set_backend_opts(backend_mod)

    case backend_mod.init(opts) do
      {:ok, ref} -> {:ok, {backend_mod, ref}}
      {:error, reason} -> {:error, {backend_mod, reason}}
    end
  end

  defp spent_set_backend_opts(Backends.DETS),
    do: [path: Paths.mint_spent_set_dets()]

  defp spent_set_backend_opts(Backends.CubDB),
    do: [data_dir: Paths.mint_spent_set()]

  defp spent_set_backend_opts(_other),
    do: [data_dir: Paths.mint_spent_set()]

  # --- Encryption ---

  @doc "Encrypts a binary value using the keyset encryption key."
  @spec encrypt(binary()) :: {:ok, binary()} | {:error, term()}
  def encrypt(data), do: Encryption.encrypt(data)

  @doc "Decrypts a previously encrypted binary."
  @spec decrypt(binary()) :: {:ok, binary()} | {:error, term()}
  def decrypt(data), do: Encryption.decrypt(data)

  @doc "Encrypts an Erlang term."
  @spec encrypt_term(term()) :: {:ok, binary()} | {:error, term()}
  def encrypt_term(term), do: Encryption.encrypt_term(term)

  @doc "Decrypts an Erlang term."
  @spec decrypt_term(binary()) :: {:ok, term()} | {:error, term()}
  def decrypt_term(data), do: Encryption.decrypt_term(data)

  # --- Recovery ---

  @doc """
  Returns the absolute path of the recovery blocked-hashes file that
  Storage.Recovery writes during boot and Mint.Spent consumes to block
  in-flight melt tokens from being re-spent.
  """
  @spec recovery_blocked_hashes_path() :: binary()
  def recovery_blocked_hashes_path, do: Recovery.blocked_hashes_path()

  # --- Backup ---

  @doc "Returns the backup directory path."
  @spec backup_dir() :: binary()
  def backup_dir, do: Paths.backups()

  # --- Paths ---

  @doc "Base data directory for all storage."
  @spec base_dir() :: binary()
  def base_dir, do: Paths.base_dir()

  @doc "DETS path for mint quotes."
  @spec mint_quotes_path() :: binary()
  def mint_quotes_path, do: Paths.mint_quotes()

  @doc "DETS path for Lightning invoices."
  @spec lightning_invoices_path() :: binary()
  def lightning_invoices_path, do: Paths.lightning_invoices()

  @doc "DETS path for Lightning invoice-to-quote mapping."
  @spec lightning_invoice_quote_map_path() :: binary()
  def lightning_invoice_quote_map_path, do: Paths.lightning_invoice_quote_map()

  @doc "DETS path for telemetry metrics."
  @spec telemetry_metrics_path() :: binary()
  def telemetry_metrics_path, do: Paths.telemetry_metrics()

  @doc "JSONL path for the operator audit log."
  @spec operator_audit_path() :: binary()
  def operator_audit_path, do: Paths.operator_audit()

  @doc "Path of the fsynced halt-state anchor file."
  @spec halt_state_path() :: binary()
  def halt_state_path, do: Paths.halt_state()

  @doc "DETS path for the mint spent set."
  @spec mint_spent_set_dets_path() :: binary()
  def mint_spent_set_dets_path, do: Paths.mint_spent_set_dets()

  @doc "DETS path for in-flight signatures awaiting client storage ACK."
  @spec mint_pending_path() :: binary()
  def mint_pending_path, do: Paths.mint_pending()

  @doc "DETS path for reserves proofs."
  @spec reserves_proofs_path() :: binary()
  def reserves_proofs_path, do: Paths.reserves_proofs()

  @doc "Directory path for key files."
  @spec keys_path() :: binary()
  def keys_path, do: Paths.keys()

  @doc "Creates the full directory tree. Call once on startup."
  @spec ensure_dirs!() :: :ok
  defdelegate ensure_dirs!, to: Paths
end
