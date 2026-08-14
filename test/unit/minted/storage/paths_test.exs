defmodule Minted.Storage.PathsTest do
  @moduledoc "Unit tests for Minted.Storage.Paths."

  use ExUnit.Case, async: true

  alias Minted.Storage.Paths

  describe "base_dir/0" do
    test "returns configured data_dir" do
      assert is_binary(Paths.base_dir())
    end
  end

  describe "context directories" do
    test "all context dirs are under base_dir" do
      base = Paths.base_dir()

      for dir <- [
            Paths.keys(),
            Paths.lightning(),
            Paths.mint(),
            Paths.recovery(),
            Paths.reserves(),
            Paths.storage(),
            Paths.telemetry()
          ] do
        assert String.starts_with?(dir, base), "#{dir} not under #{base}"
      end
    end

    test "context dirs are distinct" do
      dirs = [
        Paths.keys(),
        Paths.lightning(),
        Paths.mint(),
        Paths.recovery(),
        Paths.reserves(),
        Paths.storage(),
        Paths.telemetry()
      ]

      assert length(Enum.uniq(dirs)) == length(dirs)
    end
  end

  describe "file paths" do
    test "DETS files end with .dets" do
      for path <- [
            Paths.mint_quotes(),
            Paths.mint_spent_set_dets(),
            Paths.lightning_invoices(),
            Paths.lightning_invoice_quote_map(),
            Paths.reserves_fees(),
            Paths.reserves_liability(),
            Paths.reserves_proofs(),
            Paths.storage_state(),
            Paths.telemetry_metrics()
          ] do
        assert String.ends_with?(path, ".dets"), "#{path} does not end with .dets"
      end
    end

    test "file paths are under their context directory" do
      assert String.starts_with?(Paths.mint_quotes(), Paths.mint())
      assert String.starts_with?(Paths.mint_spent_set(), Paths.mint())
      assert String.starts_with?(Paths.lightning_invoices(), Paths.lightning())
      assert String.starts_with?(Paths.lightning_invoice_quote_map(), Paths.lightning())
      assert String.starts_with?(Paths.reserves_fees(), Paths.reserves())
      assert String.starts_with?(Paths.reserves_liability(), Paths.reserves())
      assert String.starts_with?(Paths.reserves_proofs(), Paths.reserves())
      assert String.starts_with?(Paths.storage_state(), Paths.storage())
      assert String.starts_with?(Paths.backups(), Paths.base_dir())
      assert String.starts_with?(Paths.storage_wal(), Paths.storage())
      assert String.starts_with?(Paths.telemetry_metrics(), Paths.telemetry())
      assert String.starts_with?(Paths.recovery_blocked_hashes(), Paths.recovery())
    end

    test "key file paths are under keys directory" do
      assert String.starts_with?(Paths.key_file("test-key"), Paths.keys())
      assert String.ends_with?(Paths.key_file("test-key"), ".enc")
    end

    test "no paths contain Elixir module names" do
      for path <- [
            Paths.reserves_fees(),
            Paths.reserves_liability(),
            Paths.reserves_proofs(),
            Paths.storage_state(),
            Paths.telemetry_metrics()
          ] do
        refute String.contains?(path, "Elixir."), "#{path} contains Elixir module name"
      end
    end
  end

  describe "ensure_dirs!/0" do
    test "creates the directory tree" do
      # Paths.ensure_dirs! is called by the application on startup,
      # so dirs should already exist in the test environment.
      assert File.dir?(Paths.keys())
      assert File.dir?(Paths.lightning())
      assert File.dir?(Paths.mint())
      assert File.dir?(Paths.mint_spent_set())
      assert File.dir?(Paths.recovery())
      assert File.dir?(Paths.reserves())
      assert File.dir?(Paths.storage())
      assert File.dir?(Paths.backups())
      assert File.dir?(Paths.storage_wal())
      assert File.dir?(Paths.telemetry())
    end
  end
end
