defmodule Minted.Storage.Backends.DETSTest do
  @moduledoc "Unit tests for Minted.Storage.Backends.DETS."

  use ExUnit.Case, async: false

  alias Minted.Storage.Backends.DETS, as: DETSBackend

  @test_dir Path.join(System.tmp_dir!(), "minted_test/dets_backend_test")

  setup do
    File.rm_rf!(@test_dir)
    File.mkdir_p!(@test_dir)
    table_name = :"dets_test_#{System.unique_integer([:positive])}"
    path = Path.join(@test_dir, "#{table_name}.dets")

    {:ok, table} = DETSBackend.init(path: path, table_name: table_name)

    on_exit(fn ->
      try do
        DETSBackend.close(table)
      rescue
        _ -> :ok
      end

      File.rm_rf!(@test_dir)
    end)

    %{table: table, path: path}
  end

  describe "init/1" do
    test "creates DETS file at configured path", %{path: path} do
      assert File.exists?(path)
    end
  end

  describe "put/2 and get/1" do
    test "stores and retrieves a value", %{table: table} do
      key = "test_key_1"
      value = %{keyset_id: "ks1", spent_at: 123}

      assert :ok = DETSBackend.put(table, key, value)
      assert {:ok, ^value} = DETSBackend.get(table, key)
    end

    test "returns :not_found for missing key", %{table: table} do
      assert :not_found = DETSBackend.get(table, "nonexistent")
    end
  end

  describe "member?/1" do
    test "returns true for existing key", %{table: table} do
      DETSBackend.put(table, "exists", :some_value)
      assert DETSBackend.member?(table, "exists")
    end

    test "returns false for missing key", %{table: table} do
      refute DETSBackend.member?(table, "missing")
    end
  end

  describe "size/0" do
    test "returns 0 for empty store", %{table: table} do
      assert DETSBackend.size(table) == 0
    end

    test "returns correct count after inserts", %{table: table} do
      DETSBackend.put(table, "k1", :v1)
      DETSBackend.put(table, "k2", :v2)
      DETSBackend.put(table, "k3", :v3)
      assert DETSBackend.size(table) == 3
    end

    test "does not double-count updates to same key", %{table: table} do
      DETSBackend.put(table, "k1", :v1)
      DETSBackend.put(table, "k1", :v2)
      assert DETSBackend.size(table) == 1
    end
  end

  describe "close/0" do
    test "closes cleanly", %{table: table} do
      assert :ok = DETSBackend.close(table)
    end
  end

  describe "file_size/0" do
    test "returns file size in bytes", %{table: table} do
      DETSBackend.put(table, "k", :v)
      assert {:ok, size} = DETSBackend.file_size(table)
      assert size > 0
    end
  end

  describe "near_limit?/0" do
    test "returns false for small files", %{table: table} do
      refute DETSBackend.near_limit?(table)
    end
  end
end
