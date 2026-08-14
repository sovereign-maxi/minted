defmodule Minted.Storage.Recovery.Verifier do
  @moduledoc """
  WAL integrity verification for crash recovery.

  Verifies WAL segment headers, entry CRC32 checksums, and identifies
  corrupted entries that should be quarantined.
  """

  require Logger

  alias Locker.WAL.Entry

  @magic "LWAL"
  @version 1

  @doc """
  Verifies a WAL directory, returning a report of all segments and entries.

  Returns a map with:
  - `:segments` - list of segment info maps
  - `:total_entries` - total valid entry count
  - `:corrupt_entries` - total corrupt entry count
  - `:valid` - boolean indicating overall integrity
  """
  @spec verify(binary()) :: {:ok, map()} | {:error, term()}
  def verify(wal_dir) do
    if File.dir?(wal_dir) do
      segments = list_segments(wal_dir)

      results =
        Enum.map(segments, fn path ->
          verify_segment(path)
        end)

      total_entries = Enum.sum(Enum.map(results, & &1.valid_entries))
      corrupt_entries = Enum.sum(Enum.map(results, & &1.corrupt_entries))

      report = %{
        segments: results,
        total_entries: total_entries,
        corrupt_entries: corrupt_entries,
        valid: corrupt_entries == 0
      }

      {:ok, report}
    else
      {:error, :wal_dir_not_found}
    end
  end

  @doc """
  Verifies a single WAL segment file.
  """
  @spec verify_segment(binary()) :: map()
  def verify_segment(path) do
    case File.read(path) do
      {:ok, data} ->
        case verify_header(data) do
          {:ok, entry_data} ->
            {entries, corrupt_count} = Entry.decode_all(entry_data, Minted.Storage.WAL.byte_map())

            %{
              path: path,
              header_valid: true,
              valid_entries: length(entries),
              corrupt_entries: corrupt_count,
              entries: entries
            }

          {:error, reason} ->
            Logger.warning("Verifier: invalid WAL header in #{path}: #{inspect(reason)}")

            %{
              path: path,
              header_valid: false,
              valid_entries: 0,
              corrupt_entries: 0,
              entries: [],
              error: reason
            }
        end

      {:error, reason} ->
        %{
          path: path,
          header_valid: false,
          valid_entries: 0,
          corrupt_entries: 0,
          entries: [],
          error: reason
        }
    end
  end

  @doc """
  Quarantines a corrupt WAL segment by renaming it with a `.corrupt` suffix.
  """
  @spec quarantine(binary()) :: :ok | {:error, term()}
  def quarantine(segment_path) do
    corrupt_path = segment_path <> ".corrupt"

    case File.rename(segment_path, corrupt_path) do
      :ok ->
        Logger.warning("Verifier: quarantined corrupt WAL segment, path=#{segment_path}, moved_to=#{corrupt_path}")
        :ok

      {:error, reason} ->
        {:error, {:quarantine_failed, reason}}
    end
  end

  @doc """
  Identifies uncommitted entries (entries after the last checkpoint).
  """
  @spec find_uncommitted([Entry.t()]) :: [Entry.t()]
  def find_uncommitted(entries) do
    # Find the index of the last checkpoint.
    last_checkpoint_idx =
      entries
      |> Enum.with_index()
      |> Enum.filter(fn {entry, _idx} -> entry.type == :checkpoint end)
      |> List.last()

    case last_checkpoint_idx do
      nil ->
        # No checkpoint found, all entries are uncommitted.
        entries

      {_entry, idx} ->
        # Return entries after the last checkpoint.
        Enum.drop(entries, idx + 1)
    end
  end

  # --- Private Helpers ---

  defp verify_header(<<@magic, @version::unsigned-big-16, _count::unsigned-big-32, rest::binary>>) do
    {:ok, rest}
  end

  defp verify_header(<<@magic, version::unsigned-big-16, _rest::binary>>) do
    {:error, {:unsupported_version, version}}
  end

  defp verify_header(_) do
    {:error, :invalid_magic}
  end

  defp list_segments(wal_dir) do
    case File.ls(wal_dir) do
      {:ok, files} ->
        files
        |> Enum.filter(&Regex.match?(~r/^wal\.\d{6}$/, &1))
        |> Enum.sort()
        |> Enum.map(&Path.join(wal_dir, &1))

      {:error, _} ->
        []
    end
  end
end
