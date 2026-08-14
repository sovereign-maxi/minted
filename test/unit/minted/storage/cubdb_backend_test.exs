defmodule Minted.Storage.Backends.CubDBTest do
  @moduledoc "Unit tests for Minted.Storage.Backends.CubDB."

  use ExUnit.Case, async: false

  alias Minted.Storage.Backends.CubDB, as: CubDBBackend

  @test_dir Path.join(System.tmp_dir!(), "minted_test/cubdb_backend_test")

  setup do
    File.rm_rf!(@test_dir)
    File.mkdir_p!(@test_dir)
    path = Path.join(@test_dir, "db_#{System.unique_integer([:positive])}")

    {:ok, db} = CubDBBackend.init(data_dir: path)

    on_exit(fn ->
      try do
        CubDBBackend.close(db)
      rescue
        _ -> :ok
      end

      File.rm_rf!(@test_dir)
    end)

    %{db: db, path: path}
  end

  describe "init/1" do
    test "creates data directory at configured path", %{path: path} do
      assert File.dir?(path)
    end
  end

  describe "put/3 and get/2" do
    test "stores and retrieves a value", %{db: db} do
      key = "test_key_1"
      value = {"ks1", 123}

      assert :ok = CubDBBackend.put(db, key, value)
      assert {:ok, ^value} = CubDBBackend.get(db, key)
    end

    test "returns :not_found for missing key", %{db: db} do
      assert :not_found = CubDBBackend.get(db, "nonexistent")
    end
  end

  describe "put_batch_sync/2" do
    test "inserts multiple entries atomically", %{db: db} do
      entries = [
        {"k1", {"ks1", 100}},
        {"k2", {"ks1", 101}},
        {"k3", {"ks2", 102}}
      ]

      assert :ok = CubDBBackend.put_batch_sync(db, entries)
      assert {:ok, {"ks1", 100}} = CubDBBackend.get(db, "k1")
      assert {:ok, {"ks1", 101}} = CubDBBackend.get(db, "k2")
      assert {:ok, {"ks2", 102}} = CubDBBackend.get(db, "k3")
    end
  end

  describe "member?/2" do
    test "returns true for existing key", %{db: db} do
      CubDBBackend.put(db, "exists", {"ks1", 1})
      assert CubDBBackend.member?(db, "exists")
    end

    test "returns false for missing key", %{db: db} do
      refute CubDBBackend.member?(db, "missing")
    end
  end

  describe "size/1" do
    test "returns 0 for empty store", %{db: db} do
      assert CubDBBackend.size(db) == 0
    end

    test "returns correct count after inserts", %{db: db} do
      CubDBBackend.put(db, "k1", {"ks1", 1})
      CubDBBackend.put(db, "k2", {"ks1", 2})
      CubDBBackend.put(db, "k3", {"ks1", 3})
      assert CubDBBackend.size(db) == 3
    end

    test "does not double-count updates to same key", %{db: db} do
      CubDBBackend.put(db, "k1", {"ks1", 1})
      CubDBBackend.put(db, "k1", {"ks1", 2})
      assert CubDBBackend.size(db) == 1
    end
  end

  describe "load_all/1" do
    test "returns all entries", %{db: db} do
      CubDBBackend.put(db, "k1", {"ks1", 1})
      CubDBBackend.put(db, "k2", {"ks2", 2})

      entries = CubDBBackend.load_all(db)
      assert length(entries) == 2
      assert {"k1", {"ks1", 1}} in entries
      assert {"k2", {"ks2", 2}} in entries
    end

    test "returns empty list for empty store", %{db: db} do
      assert CubDBBackend.load_all(db) == []
    end
  end

  describe "delete_match/2" do
    test "removes entries matching keyset_id", %{db: db} do
      CubDBBackend.put(db, "h1", {"ks_target", 1})
      CubDBBackend.put(db, "h2", {"ks_target", 2})
      CubDBBackend.put(db, "h3", {"ks_keep", 3})
      CubDBBackend.put(db, {:y, "y1"}, {"ks_target", 4})

      removed = CubDBBackend.delete_match(db, "ks_target")
      assert removed == 3

      assert :not_found = CubDBBackend.get(db, "h1")
      assert :not_found = CubDBBackend.get(db, "h2")
      assert {:ok, {"ks_keep", 3}} = CubDBBackend.get(db, "h3")
      assert :not_found = CubDBBackend.get(db, {:y, "y1"})
    end

    test "returns 0 when no entries match", %{db: db} do
      CubDBBackend.put(db, "h1", {"ks_other", 1})
      assert CubDBBackend.delete_match(db, "ks_nonexistent") == 0
    end
  end

  describe "close/1" do
    test "closes cleanly", %{db: db} do
      assert :ok = CubDBBackend.close(db)
    end
  end
end
