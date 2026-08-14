defmodule Minted.Storage.WAL do
  @moduledoc false

  @type_map %{
    keyset_created: 0x01,
    proof_spent: 0x02,
    config_changed: 0x03,
    keyset_rotated: 0x04,
    epoch_advanced: 0x05,
    checkpoint: 0x06,
    keyset_expired: 0x07,
    tokens_minted: 0x08,
    tokens_burned: 0x09,
    payments_in_flight: 0x0A,
    wallet_tokens_stored: 0x0B,
    wallet_tokens_removed: 0x0C,
    wallet_tokens_swapped: 0x0D,
    proof_stored: 0x0E,
    wallet_activity_added: 0x0F,
    melt_started: 0x10,
    melt_settled: 0x11,
    swap_started: 0x12,
    swap_settled: 0x13,
    fees_collected: 0x14,
    # 0x15, 0x16 reserved (previously onchain_swap_created, onchain_swap_tracked)
    house_withdrawal_requested: 0x17,
    house_withdrawal_completed: 0x18,
    house_withdrawal_rejected: 0x19,
    # Swap failures — the swap service writes this on any pre-commit
    # failure so operator forensics can reconstruct the attempt.
    swap_failed: 0x1A
  }

  @byte_map Map.new(@type_map, fn {k, v} -> {v, k} end)

  def type_map, do: @type_map
  def byte_map, do: @byte_map
  def server_name, do: Minted.Storage.WAL
end
