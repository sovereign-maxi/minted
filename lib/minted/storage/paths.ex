defmodule Minted.Storage.Paths do
  @moduledoc """
  Centralised, configurable data paths for all persistent storage.

  Modules call functions here rather than constructing paths themselves.
  The base directory is read from application config `:minted, :data_dir`.
  """

  # --- Base ---

  @spec base_dir() :: String.t()
  def base_dir, do: Application.get_env(:minted, :data_dir, "data")

  # --- Context Directories ---

  @spec keys() :: String.t()
  def keys, do: Path.join(base_dir(), "keys")

  @spec lightning() :: String.t()
  def lightning, do: Path.join(base_dir(), "lightning")

  @spec mint() :: String.t()
  def mint, do: Path.join(base_dir(), "mint")

  @spec recovery() :: String.t()
  def recovery, do: Path.join(base_dir(), "recovery")

  @spec reserves() :: String.t()
  def reserves, do: Path.join(base_dir(), "reserves")

  @spec storage() :: String.t()
  def storage, do: Path.join(base_dir(), "storage")

  @spec telemetry() :: String.t()
  def telemetry, do: Path.join(base_dir(), "telemetry")

  # --- Keys ---

  @spec key_file(String.t()) :: String.t()
  def key_file(label), do: Path.join(keys(), "#{label}.enc")

  # --- Lightning ---

  @spec lightning_invoices() :: String.t()
  def lightning_invoices, do: Path.join(lightning(), "invoices.dets")

  @spec lightning_invoice_quote_map() :: String.t()
  def lightning_invoice_quote_map, do: Path.join(lightning(), "invoice_quote_map.dets")

  # --- Mint ---

  @spec mint_quotes() :: String.t()
  def mint_quotes, do: Path.join(mint(), "quotes.dets")

  @spec mint_spent_set() :: String.t()
  def mint_spent_set, do: Path.join(mint(), "spent_set")

  @spec mint_spent_set_dets() :: String.t()
  def mint_spent_set_dets, do: Path.join(mint(), "spent_set.dets")

  @spec mint_pending() :: String.t()
  def mint_pending, do: Path.join(mint(), "pending.dets")

  # --- Recovery ---

  @spec recovery_blocked_hashes() :: String.t()
  def recovery_blocked_hashes, do: Path.join(recovery(), "blocked_hashes.bin")

  @spec halt_state() :: String.t()
  def halt_state, do: Path.join(recovery(), "halt_state")

  # --- Reserves ---

  @spec reserves_fees() :: String.t()
  def reserves_fees, do: Path.join(reserves(), "fees.dets")

  @spec reserves_liability() :: String.t()
  def reserves_liability, do: Path.join(reserves(), "liability.dets")

  @spec reserves_proofs() :: String.t()
  def reserves_proofs, do: Path.join(reserves(), "proofs.dets")

  # --- Backups ---

  @spec backups() :: String.t()
  def backups, do: Path.join(base_dir(), "backups")

  # --- Storage ---

  @spec storage_state() :: String.t()
  def storage_state, do: Path.join(storage(), "state.dets")

  @spec storage_wal() :: String.t()
  def storage_wal, do: Path.join(storage(), "wal")

  # --- Telemetry ---

  @spec telemetry_metrics() :: String.t()
  def telemetry_metrics, do: Path.join(telemetry(), "metrics.dets")

  @spec operator_audit() :: String.t()
  def operator_audit, do: Path.join(telemetry(), "operator_audit.jsonl")

  # --- Directory Management ---

  @doc """
  Creates the full directory tree. Call once on application startup
  before any supervisor starts.
  """
  @spec ensure_dirs!() :: :ok
  def ensure_dirs! do
    dirs = [
      backups(),
      keys(),
      lightning(),
      mint(),
      mint_spent_set(),
      recovery(),
      reserves(),
      storage(),
      storage_wal(),
      telemetry()
    ]

    Enum.each(dirs, fn dir ->
      File.mkdir_p!(dir)
      File.chmod(dir, 0o700)
    end)

    :ok
  end
end
