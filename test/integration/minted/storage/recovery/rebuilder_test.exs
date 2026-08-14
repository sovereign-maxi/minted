defmodule Minted.Storage.Recovery.RebuilderIntegrationTest do
  @moduledoc "Integration tests for WAL-based state rebuilder recovery logic."

  use Minted.IntegrationCase

  alias Locker.WAL.Entry
  alias Minted.Storage.Recovery.Rebuilder

  # Test-owned ETS table — uses the test module's own name rather than a
  # bare atom so it cannot collide with production tables.
  @table __MODULE__

  setup do
    # Ensure the test table exists and is empty before each test. :public
    # access lets ExUnit's on_exit handler (which runs in a separate
    # process) tear it down deterministically between tests.
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
    else
      :ets.delete_all_objects(@table)
    end

    :ok
  end

  describe "rebuild_keysets_from_wal/2" do
    test "rebuilds keyset_created entries" do
      keyset = %{id: "ks-1", active: true, private_keys: %{1 => "key1"}}
      entries = [%Entry{type: :keyset_created, payload: keyset}]

      assert {:ok, 1} = Rebuilder.rebuild_keysets_from_wal(entries, @table)
      assert [{_, stored}] = :ets.lookup(@table, "ks-1")
      assert stored.active == true
    end

    test "rebuilds keyset_rotated entries" do
      old = %{id: "ks-old", active: true, private_keys: %{1 => "key1"}}
      new = %{id: "ks-new", active: true, private_keys: %{1 => "key2"}}

      entries = [
        %Entry{type: :keyset_created, payload: old},
        %Entry{type: :keyset_rotated, payload: %{old_keyset_id: "ks-old", new_keyset: new}}
      ]

      assert {:ok, 2} = Rebuilder.rebuild_keysets_from_wal(entries, @table)

      [{_, old_stored}] = :ets.lookup(@table, "ks-old")
      assert old_stored.active == false

      [{_, new_stored}] = :ets.lookup(@table, "ks-new")
      assert new_stored.active == true
    end

    test "rebuilds keyset_expired entries" do
      keyset = %{id: "ks-expire", active: true, expired: false, private_keys: %{1 => "key1"}}

      entries = [
        %Entry{type: :keyset_created, payload: keyset},
        %Entry{type: :keyset_expired, payload: %{keyset_id: "ks-expire"}}
      ]

      assert {:ok, 2} = Rebuilder.rebuild_keysets_from_wal(entries, @table)

      [{_, stored}] = :ets.lookup(@table, "ks-expire")
      assert stored.active == false
      assert stored.expired == true
    end

    test "returns 0 for empty entry list" do
      assert {:ok, 0} = Rebuilder.rebuild_keysets_from_wal([], @table)
    end

    test "skips non-keyset entries" do
      entries = [
        %Entry{type: :proof_spent, payload: %{secret: "abc"}},
        %Entry{type: :config_changed, payload: %{key: "val"}},
        %Entry{type: :checkpoint, payload: %{}}
      ]

      assert {:ok, 0} = Rebuilder.rebuild_keysets_from_wal(entries, @table)
    end

    test "handles encrypted private keys" do
      # When private_keys is not {:encrypted, _}, it passes through unmodified.
      keyset = %{id: "ks-plain", active: true, private_keys: %{1 => "plain_key"}}
      entries = [%Entry{type: :keyset_created, payload: keyset}]

      assert {:ok, 1} = Rebuilder.rebuild_keysets_from_wal(entries, @table)
      [{_, stored}] = :ets.lookup(@table, "ks-plain")
      assert stored.private_keys == %{1 => "plain_key"}
    end
  end
end
