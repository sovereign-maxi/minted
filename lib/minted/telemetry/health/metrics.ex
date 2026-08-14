defmodule Minted.Telemetry.Health.Metrics do
  @moduledoc """
  System-level metrics for health monitoring.

  Reads CPU, memory, and disk usage from the OS via /proc and df.
  Pure functions — no state, no GenServer. Called by alert rules.
  """

  @doc "Returns CPU usage as a percentage (0.0 to 100.0)."
  @spec cpu_usage() :: float()
  def cpu_usage do
    case File.read("/proc/stat") do
      {:ok, content} ->
        [line | _] = String.split(content, "\n")
        calculate_cpu(line)

      _ ->
        0.0
    end
  end

  @doc "Returns memory usage as a percentage (0.0 to 100.0)."
  @spec memory_usage() :: float()
  def memory_usage do
    case File.read("/proc/meminfo") do
      {:ok, content} ->
        info = parse_meminfo(content)
        total = Map.get(info, "MemTotal", 1)
        available = Map.get(info, "MemAvailable", total)

        if total > 0 do
          Float.round((1.0 - available / total) * 100, 1)
        else
          0.0
        end

      _ ->
        0.0
    end
  end

  @doc "Returns disk usage as a percentage for the given path (0.0 to 100.0), or nil on failure."
  @spec disk_usage(String.t()) :: float() | nil
  def disk_usage(path \\ "/") do
    case System.cmd("df", ["--output=pcent", path], stderr_to_stdout: true) do
      {output, 0} ->
        output
        |> String.split("\n", trim: true)
        |> List.last()
        |> String.trim()
        |> String.trim_trailing("%")
        |> String.to_integer()
        |> Kernel./(1)

      _ ->
        nil
    end
  rescue
    _ -> nil
  end

  @doc """
  Returns a snapshot of all system metrics.

  Disk mounts are configurable via `:minted, :disk_mounts` (default `["/"]`).
  Each mount produces a `{label, percentage}` tuple in the `:disks` list.
  """
  @spec snapshot() :: map()
  def snapshot do
    mounts = Application.get_env(:minted, :disk_mounts, ["/"])

    disks =
      Enum.map(mounts, fn path ->
        {path, disk_usage(path) || 0.0}
      end)

    %{
      cpu_pct: cpu_usage(),
      memory_pct: memory_usage(),
      load_avg: load_average(),
      disks: disks,
      beam_memory_mb: Float.round(:erlang.memory(:total) / 1_048_576, 1),
      beam_ets_mb: Float.round(:erlang.memory(:ets) / 1_048_576, 1),
      beam_processes: :erlang.system_info(:process_count),
      beam_ports: :erlang.system_info(:port_count),
      beam_atoms: :erlang.system_info(:atom_count),
      beam_schedulers: :erlang.system_info(:schedulers_online),
      beam_run_queue: :erlang.statistics(:total_run_queue_lengths_all),
      uptime_hours:
        Float.round(
          (System.monotonic_time(:millisecond) -
             :persistent_term.get(:app_started_at, System.monotonic_time(:millisecond))) /
            3_600_000,
          1
        )
    }
  end

  # --- Private ---

  defp load_average do
    case File.read("/proc/loadavg") do
      {:ok, data} ->
        case String.split(data) do
          [l1, l5, l15 | _] -> "#{l1} #{l5} #{l15}"
          _ -> "n/a"
        end

      _ ->
        "n/a"
    end
  rescue
    _ -> "n/a"
  end

  # CPU usage from /proc/stat requires two samples. For simplicity,
  # we use the cumulative values and compare idle vs total.
  # This gives an average since boot, not instantaneous — good enough
  # for alerting thresholds.
  defp calculate_cpu(cpu_line) do
    parts =
      cpu_line
      |> String.split()
      |> Enum.drop(1)
      |> Enum.map(&String.to_integer/1)

    case parts do
      [user, nice, system, idle, iowait, irq, softirq | _rest] ->
        total = user + nice + system + idle + iowait + irq + softirq
        busy = total - idle - iowait

        if total > 0 do
          Float.round(busy / total * 100, 1)
        else
          0.0
        end

      _ ->
        0.0
    end
  rescue
    _ -> 0.0
  end

  defp parse_meminfo(content) do
    content
    |> String.split("\n", trim: true)
    |> Enum.reduce(%{}, fn line, acc ->
      case String.split(line, ":") do
        [key, value] ->
          kb =
            value
            |> String.trim()
            |> String.split()
            |> List.first()
            |> String.to_integer()

          Map.put(acc, String.trim(key), kb)

        _ ->
          acc
      end
    end)
  rescue
    _ -> %{}
  end
end
