defmodule Minted.Storage.WALTest do
  @moduledoc "Unit tests for Minted.Storage.WAL."

  use ExUnit.Case, async: false

  alias Minted.Storage.WAL

  @expected_types %{
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
    swap_failed: 0x1A
  }

  describe "type_map/0" do
    test "returns a map of all event types to byte codes" do
      type_map = WAL.type_map()
      assert is_map(type_map)
      assert type_map == @expected_types
    end

    test "has 24 event types" do
      assert map_size(WAL.type_map()) == 24
    end

    test "all keys are atoms" do
      for {key, _val} <- WAL.type_map() do
        assert is_atom(key)
      end
    end

    test "all values are positive integers" do
      for {_key, val} <- WAL.type_map() do
        assert is_integer(val) and val > 0
      end
    end

    test "all byte codes are unique" do
      values = Map.values(WAL.type_map())
      assert length(values) == length(Enum.uniq(values))
    end

    test "byte codes cover 0x01..0x14 and 0x17..0x1A (0x15, 0x16 reserved)" do
      values = WAL.type_map() |> Map.values() |> Enum.sort()
      assert values == Enum.to_list(0x01..0x14) ++ [0x17, 0x18, 0x19, 0x1A]
    end
  end

  describe "byte_map/0" do
    test "returns the inverse of type_map" do
      byte_map = WAL.byte_map()
      type_map = WAL.type_map()

      assert map_size(byte_map) == map_size(type_map)

      for {name, byte} <- type_map do
        assert byte_map[byte] == name
      end
    end

    test "all keys are integers" do
      for {key, _val} <- WAL.byte_map() do
        assert is_integer(key)
      end
    end

    test "all values are atoms" do
      for {_key, val} <- WAL.byte_map() do
        assert is_atom(val)
      end
    end

    test "round-trips with type_map" do
      for {name, byte} <- WAL.type_map() do
        assert WAL.byte_map()[byte] == name
        assert WAL.type_map()[name] == byte
      end
    end
  end

  describe "server_name/0" do
    test "returns the WAL server name atom" do
      assert WAL.server_name() == Minted.Storage.WAL
    end

    test "returns an atom" do
      assert is_atom(WAL.server_name())
    end
  end
end
