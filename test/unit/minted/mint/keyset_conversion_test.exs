defmodule Minted.Mint.KeysetConversionTest do
  @moduledoc "Unit tests for Minted.Mint.Keyset conversion logic."

  use ExUnit.Case, async: true

  alias Minted.Mint.Keyset

  describe "from_store_map/1" do
    test "converts store map with separate public/private keys to Keyset struct" do
      store_map = %{
        id: "abc123",
        unit: "sat",
        active: true,
        expired: false,
        public_keys: %{1 => "pub1", 2 => "pub2"},
        private_keys: %{1 => "priv1", 2 => "priv2"},
        created_at: ~U[2025-01-01 00:00:00Z]
      }

      assert {:ok, keyset} = Keyset.from_store_map(store_map)

      assert %Keyset{} = keyset
      assert keyset.id == "abc123"
      assert keyset.unit == "sat"
      assert keyset.status == :active
      assert keyset.keys == %{1 => {"priv1", "pub1"}, 2 => {"priv2", "pub2"}}
      assert keyset.created_at == ~U[2025-01-01 00:00:00Z]
    end

    test "sets status to :retired when active is false" do
      store_map = %{
        id: "abc123",
        active: false,
        expired: false,
        public_keys: %{},
        private_keys: %{}
      }

      assert {:ok, keyset} = Keyset.from_store_map(store_map)
      assert keyset.status == :retired
    end

    test "sets status to :expired when expired is true" do
      store_map = %{
        id: "abc123",
        active: false,
        expired: true,
        public_keys: %{},
        private_keys: %{}
      }

      assert {:ok, keyset} = Keyset.from_store_map(store_map)
      assert keyset.status == :expired
    end

    test "returns error on missing private keys" do
      store_map = %{
        id: "abc123",
        active: true,
        public_keys: %{1 => "pub1"},
        private_keys: %{}
      }

      assert {:error, {:missing_key, 1}} = Keyset.from_store_map(store_map)
    end

    test "defaults unit to sat when not present" do
      store_map = %{
        id: "abc123",
        active: true,
        public_keys: %{},
        private_keys: %{}
      }

      assert {:ok, keyset} = Keyset.from_store_map(store_map)
      assert keyset.unit == "sat"
    end
  end
end
