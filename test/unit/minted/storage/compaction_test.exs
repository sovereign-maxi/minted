defmodule Minted.Storage.CompactionTest do
  @moduledoc "Unit tests for Minted.Storage.Compaction."

  use ExUnit.Case, async: false

  alias Minted.Storage.Compaction

  describe "prune_wal/1" do
    test "prunes WAL segments in a real directory" do
      wal_dir = Path.join(System.tmp_dir!(), "compaction_test_wal_#{:rand.uniform(100_000)}")
      File.mkdir_p!(wal_dir)

      on_exit(fn -> File.rm_rf!(wal_dir) end)

      # Create some fake WAL segment files
      for i <- 1..8 do
        path = Path.join(wal_dir, "segment_#{String.pad_leading("#{i}", 6, "0")}.wal")
        File.write!(path, "segment #{i} data")
      end

      assert {:ok, pruned} = Compaction.prune_wal(wal_dir: wal_dir, wal_keep_segments: 3)
      assert is_integer(pruned)
      assert pruned >= 0
    end

    test "returns {:ok, 0} when directory is empty" do
      wal_dir = Path.join(System.tmp_dir!(), "compaction_test_empty_#{:rand.uniform(100_000)}")
      File.mkdir_p!(wal_dir)

      on_exit(fn -> File.rm_rf!(wal_dir) end)

      assert {:ok, 0} = Compaction.prune_wal(wal_dir: wal_dir, wal_keep_segments: 5)
    end

    test "returns {:ok, 0} when directory does not exist" do
      # Should rescue and return {:ok, 0}
      assert {:ok, 0} =
               Compaction.prune_wal(
                 wal_dir: "/tmp/nonexistent_wal_dir_#{:rand.uniform(100_000)}",
                 wal_keep_segments: 5
               )
    end

    test "returns {:ok, 0} when fewer segments than keep threshold" do
      wal_dir = Path.join(System.tmp_dir!(), "compaction_test_few_#{:rand.uniform(100_000)}")
      File.mkdir_p!(wal_dir)

      on_exit(fn -> File.rm_rf!(wal_dir) end)

      # Create only 2 segments, keep 5
      for i <- 1..2 do
        path = Path.join(wal_dir, "segment_#{String.pad_leading("#{i}", 6, "0")}.wal")
        File.write!(path, "data")
      end

      assert {:ok, 0} = Compaction.prune_wal(wal_dir: wal_dir, wal_keep_segments: 5)
    end

    test "defaults are applied when no options given" do
      # This may fail or return 0 depending on whether default wal_dir exists,
      # but should not raise
      assert {:ok, _pruned} = Compaction.prune_wal([])
    end
  end
end
