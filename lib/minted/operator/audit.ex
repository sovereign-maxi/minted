defmodule Minted.Operator.Audit do
  @moduledoc """
  Append-only operator-action audit log.

  EventBus broadcasts of halt / resume / force-operations are
  local-PubSub only — useful for a live dashboard but lost the
  moment no subscriber is up. This log persists those events as
  one JSON object per line in `{telemetry_dir}/operator_audit.jsonl`
  so the forensic record survives reboots, dashboard outages, and
  operator inattention.

  Single-writer per node. Lines are flushed on write so a crash
  mid-second does not lose the last event.

  ## Halt-state recovery

  `replay_halt_state/0` scans the audit file once at boot and, if
  the most recent halt-related entry is `:halt_set`, re-establishes
  the persistent_term halt flag before the supervisor tree starts
  accepting traffic. Without this, an operator who halts during an
  incident and then `systemctl restart`s for any reason finds the
  mint silently re-enabled.
  """

  require Logger

  alias Minted.Storage.Facade, as: StorageFacade

  @halt_set :halt_set
  @halt_cleared :halt_cleared

  @doc """
  Appends an operator-action event. `kind` is a snake_case atom
  (e.g. `:halt_set`, `:halt_cleared`, `:force_mint`); `details` is a
  map of JSON-serialisable values.

  Returns `:ok` on success, `{:error, reason}` when the append
  failed. Best-effort callers may ignore the result; durability-
  critical state (the halt flag) is persisted separately — see
  `Minted.Telemetry.Health.System.set_halted/1`.
  """
  @spec record(atom(), map()) :: :ok | {:error, term()}
  def record(kind, details) when is_atom(kind) and is_map(details) do
    line =
      Jason.encode!(%{
        timestamp: DateTime.to_iso8601(DateTime.utc_now()),
        node: Atom.to_string(node()),
        kind: kind,
        details: stringify(details)
      }) <> "\n"

    path = log_path()
    File.mkdir_p!(Path.dirname(path))

    case File.open(path, [:append, :sync]) do
      {:ok, fd} ->
        try do
          :ok = IO.binwrite(fd, line)
        after
          File.close(fd)
        end

        File.chmod(path, 0o600)
        :ok

      {:error, reason} ->
        Logger.error("Audit: append failed, reason=#{inspect(reason)}")
        {:error, reason}
    end
  rescue
    error ->
      Logger.error("Audit: record failed, reason=#{inspect(error)}")
      {:error, error}
  end

  @doc """
  Restores halt state. The fsynced state file written by
  `set_halted/1` is authoritative; the audit-log scan is the fallback
  for halt records that predate the state file. Called once at
  application start before the supervisor tree comes up.
  """
  @spec replay_halt_state() :: {:halted, String.t()} | :clear
  def replay_halt_state do
    case read_halt_state_file() do
      {:ok, reason} ->
        restore_halt_flag(reason, "state file")

      :absent ->
        replay_halt_state_from_log()
    end
  rescue
    _ -> :clear
  end

  defp read_halt_state_file do
    path = StorageFacade.halt_state_path()

    case File.read(path) do
      {:ok, reason} ->
        {:ok, reason}

      {:error, :enoent} ->
        :absent

      {:error, reason} ->
        Logger.warning("Audit: halt state file unreadable, reason=#{inspect(reason)} — falling back to log scan")
        :absent
    end
  end

  defp replay_halt_state_from_log do
    case latest_halt_entry() do
      {@halt_set, reason} ->
        restore_halt_flag(reason, "log")

      _ ->
        :clear
    end
  rescue
    _ -> :clear
  end

  defp restore_halt_flag(reason, source) do
    :persistent_term.put(
      {Minted.Telemetry.Health.System, :halted},
      {true, reason}
    )

    Logger.warning("Audit: restored halt state from #{source}, reason=#{reason}")
    {:halted, reason}
  end

  @doc "Returns the absolute path of the audit log."
  @spec log_path() :: String.t()
  def log_path, do: StorageFacade.operator_audit_path()

  # --- Internal ---

  defp latest_halt_entry do
    path = log_path()

    if File.exists?(path) do
      scan_halt_entries(path)
    else
      nil
    end
  end

  defp scan_halt_entries(path) do
    path
    |> File.stream!(:line)
    |> Stream.map(&decode_line/1)
    |> Stream.reject(&is_nil/1)
    |> Enum.reduce(nil, fn entry, latest ->
      case entry["kind"] do
        "halt_set" -> {@halt_set, get_in(entry, ["details", "reason"]) || ""}
        "halt_cleared" -> {@halt_cleared, ""}
        _ -> latest
      end
    end)
  end

  defp decode_line(line) do
    case Jason.decode(String.trim(line)) do
      {:ok, map} -> map
      _ -> nil
    end
  end

  defp stringify(map) do
    Map.new(map, fn {k, v} -> {to_string(k), serialize(v)} end)
  end

  defp serialize(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp serialize(value) when is_atom(value) and value not in [nil, true, false], do: Atom.to_string(value)

  defp serialize(value) when is_binary(value) or is_number(value) or value in [nil, true, false],
    do: value

  defp serialize(value) when is_list(value), do: Enum.map(value, &serialize/1)
  defp serialize(value) when is_map(value), do: stringify(value)
  defp serialize(value), do: inspect(value)
end
