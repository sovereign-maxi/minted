defmodule Minted.TestHelpers.ProcessHelpers do
  @moduledoc """
  Helpers for safe GenServer lifecycle management in tests.

  Prefer polling helpers (`await_dead/2`, `await_restart/3`, `await_condition/2`)
  over `Process.sleep` or `:timer.sleep` — fixed sleeps are race conditions.
  """

  @doc """
  Stops a GenServer safely, catching exits if the process is already dead.

  Use in `on_exit` callbacks to avoid race conditions between linked process
  termination and cleanup:

      on_exit(fn -> safe_stop(pid) end)
  """
  @spec safe_stop(pid() | atom(), timeout()) :: :ok
  def safe_stop(pid_or_name, timeout \\ 5_000) do
    GenServer.stop(pid_or_name, :normal, timeout)
    :ok
  catch
    :exit, _ -> :ok
  end

  @doc """
  Polls until `pid` is dead. Raises if still alive after `timeout_ms`.
  """
  @spec await_dead(pid(), pos_integer()) :: :ok
  def await_dead(pid, timeout_ms \\ 5_000) do
    await_condition(fn -> not Process.alive?(pid) end, timeout_ms)
  end

  @doc """
  Polls until a new process is registered under `name` (different from `old_pid`).
  Returns the new pid. Raises on timeout.
  """
  @spec await_restart(atom(), pid(), pos_integer()) :: pid()
  def await_restart(name, old_pid, timeout_ms \\ 5_000) do
    await_condition(
      fn ->
        case Process.whereis(name) do
          nil -> false
          ^old_pid -> false
          new_pid -> Process.alive?(new_pid)
        end
      end,
      timeout_ms
    )

    Process.whereis(name)
  end

  @doc """
  Polls `fun` every 10ms until it returns a truthy value or `timeout_ms` expires.
  Raises on timeout.

  Use instead of `Process.sleep` when waiting for async state changes:

      await_condition(fn -> LiabilityTracker.minted_total() > 0 end)
  """
  @spec await_condition((-> boolean()), pos_integer()) :: :ok
  def await_condition(fun, timeout_ms \\ 5_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_poll(fun, deadline)
  end

  defp do_poll(fun, deadline) do
    if fun.() do
      :ok
    else
      if System.monotonic_time(:millisecond) >= deadline do
        raise "await_condition timed out after #{deadline}ms"
      end

      Process.sleep(10)
      do_poll(fun, deadline)
    end
  end
end
