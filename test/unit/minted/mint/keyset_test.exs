defmodule Minted.Mint.KeysetTest do
  @moduledoc "Unit tests for Minted.Mint.Keyset."

  use ExUnit.Case, async: true

  alias Minted.Mint.Keyset

  describe "generate/0" do
    test "creates 21 denomination keys" do
      keyset = Keyset.generate()
      assert map_size(keyset.keys) == 21
    end

    test "keys cover 2^0 through 2^20" do
      keyset = Keyset.generate()

      for exp <- 0..20 do
        denom = Integer.pow(2, exp)
        assert Map.has_key?(keyset.keys, denom), "missing denomination #{denom}"
      end
    end

    test "each key pair has 32-byte privkey and 33-byte pubkey" do
      keyset = Keyset.generate()

      for {_denom, {priv, pub}} <- keyset.keys do
        assert byte_size(priv) == 32
        assert byte_size(pub) == 33
      end
    end

    test "starts with active status" do
      keyset = Keyset.generate()
      assert keyset.status == :active
    end

    test "has a non-empty string id" do
      keyset = Keyset.generate()
      assert is_binary(keyset.id)
      assert String.length(keyset.id) == 16
    end

    test "defaults to sat unit" do
      keyset = Keyset.generate()
      assert keyset.unit == "sat"
    end

    test "accepts custom unit" do
      keyset = Keyset.generate(unit: "usd")
      assert keyset.unit == "usd"
    end
  end

  describe "derive_id/1" do
    test "returns a 16-char hex string" do
      keyset = Keyset.generate()
      id = Keyset.derive_id(keyset.keys)
      assert byte_size(id) == 16
      assert Regex.match?(~r/^[0-9a-f]{16}$/, id)
    end

    test "is deterministic for same keys" do
      keyset = Keyset.generate()
      id1 = Keyset.derive_id(keyset.keys)
      id2 = Keyset.derive_id(keyset.keys)
      assert id1 == id2
    end

    test "differs for different keys" do
      keyset1 = Keyset.generate()
      keyset2 = Keyset.generate()
      assert Keyset.derive_id(keyset1.keys) != Keyset.derive_id(keyset2.keys)
    end
  end

  describe "retire/1" do
    test "transitions active to retired" do
      keyset = Keyset.generate()
      assert {:ok, retired} = Keyset.retire(keyset)
      assert retired.status == :retired
      assert %DateTime{} = retired.rotated_at
    end

    test "rejects retired keyset" do
      keyset = Keyset.generate()
      {:ok, retired} = Keyset.retire(keyset)
      assert {:error, :invalid_transition} = Keyset.retire(retired)
    end

    test "rejects expired keyset" do
      keyset = Keyset.generate()
      {:ok, retired} = Keyset.retire(keyset)
      {:ok, expired} = Keyset.expire(retired)
      assert {:error, :invalid_transition} = Keyset.retire(expired)
    end
  end

  describe "expire/1" do
    test "transitions retired to expired" do
      keyset = Keyset.generate()
      {:ok, retired} = Keyset.retire(keyset)
      assert {:ok, expired} = Keyset.expire(retired)
      assert expired.status == :expired
    end

    test "rejects active keyset" do
      keyset = Keyset.generate()
      assert {:error, :invalid_transition} = Keyset.expire(keyset)
    end

    test "rejects already expired keyset" do
      keyset = Keyset.generate()
      {:ok, retired} = Keyset.retire(keyset)
      {:ok, expired} = Keyset.expire(retired)
      assert {:error, :invalid_transition} = Keyset.expire(expired)
    end
  end

  describe "from_store_map/1" do
    test "reconstructs keyset from store format" do
      keyset = Keyset.generate()
      pub_keys = Keyset.public_keys(keyset)
      priv_keys = Map.new(keyset.keys, fn {d, {priv, _pub}} -> {d, priv} end)

      store_map = %{
        id: keyset.id,
        unit: "sat",
        public_keys: pub_keys,
        private_keys: priv_keys,
        active: true,
        expired: false,
        created_at: keyset.created_at
      }

      assert {:ok, rebuilt} = Keyset.from_store_map(store_map)
      assert rebuilt.id == keyset.id
      assert rebuilt.status == :active
      assert map_size(rebuilt.keys) == 21
    end

    test "detects expired status" do
      keyset = Keyset.generate()
      pub_keys = Keyset.public_keys(keyset)
      priv_keys = Map.new(keyset.keys, fn {d, {priv, _pub}} -> {d, priv} end)

      store_map = %{
        id: keyset.id,
        public_keys: pub_keys,
        private_keys: priv_keys,
        active: false,
        expired: true
      }

      assert {:ok, rebuilt} = Keyset.from_store_map(store_map)
      assert rebuilt.status == :expired
    end
  end

  describe "get_key/2" do
    test "returns key pair for valid denomination" do
      keyset = Keyset.generate()
      assert {:ok, {priv, pub}} = Keyset.get_key(keyset, 1)
      assert byte_size(priv) == 32
      assert byte_size(pub) == 33
    end

    test "returns error for invalid denomination" do
      keyset = Keyset.generate()
      assert {:error, :denomination_not_found} = Keyset.get_key(keyset, 3)
    end

    test "returns error for zero denomination" do
      keyset = Keyset.generate()
      assert {:error, :denomination_not_found} = Keyset.get_key(keyset, 0)
    end
  end
end
