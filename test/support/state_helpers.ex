defmodule Minted.TestHelpers.StateHelpers do
  @moduledoc """
  Centralized ETS cleanup for test isolation.

  Call `clean_state/1` via `setup :clean_state` to ensure no
  test-produced state leaks between tests. Only clears tables
  that accumulate entries during tests — never clears init-populated
  config tables (alert_rules, keysets, system_health).
  """

  alias Minted.Lightning.{Executor, Manager, Monitor}
  alias Minted.Mint.Keyset
  alias Minted.Mint.Services.Quotes
  alias Minted.Mint.Spent
  alias Minted.Reserves.Trackers.Liability
  alias Minted.Storage.Facade, as: StorageFacade

  @doc """
  ExUnit setup callback — import this module and use `setup :clean_state`.
  """
  def clean_state(_context \\ %{}) do
    clean_all_tables()
    clear_halt()
    :ok
  end

  @doc """
  Seeds a test keyset into the Store via the proper API path. Call in
  setup for any test that depends on an active keyset existing (signing,
  swapping, etc.). The keyset is generated locally via `Keyset.generate/0`
  — this is correct for tests since they run single-node.
  """
  def seed_test_keyset do
    keyset = Keyset.generate()
    StorageFacade.put_keyset(Keyset.to_store_map(keyset))
  rescue
    _e -> :ok
  catch
    :exit, _ -> :ok
  end

  @doc "Clears any halt flag left by previous tests."
  def clear_halt do
    Minted.Telemetry.Health.System.clear_halt()
  rescue
    _ -> :ok
  end

  @doc """
  Clears test-produced state from all known ETS tables.
  Safe to call unconditionally — guarded against missing tables.
  """
  @spec clean_all_tables() :: :ok
  def clean_all_tables do
    # --- Mint domain (GenServer-managed clear) ---
    safe_clear(Spent)
    safe_clear(Quotes)

    # --- Lightning domain (GenServer-managed clear) ---
    safe_clear(Manager)
    safe_clear(Monitor)
    safe_clear(Executor)
    safe_call(fn -> Minted.Lightning.Breaker.clear() end)

    # --- Identity domain ---
    safe_call(fn -> Seer.NonceStore.clear() end)
    safe_ets_clear(Minted.Identity.Escalation)
    safe_ets_clear(Seer.RateLimiter)
    safe_ets_clear(Seer.Escalation)

    # --- Lightning webhook dedup + rate limit (owned by ETSHolder) ---
    safe_ets_clear(FireBird.Webhook)
    safe_ets_clear(FireBird.Webhook.RateLimit)

    # --- Telemetry counters (test-produced metrics) ---
    safe_ets_clear(Minted.Telemetry.Metrics.Store)
    safe_ets_clear(Minted.Telemetry.Metrics.Collector)

    # --- Oracle price cache ---
    safe_ets_clear(Minted.Oracle.Feed)

    # --- Reserve proofs ---
    safe_ets_clear(Vault.Generator)

    # --- Liability and fee counters (accumulated across tests) ---
    safe_call(fn -> Liability.reset_counters() end)
    safe_call(fn -> Minted.Reserves.Trackers.Fees.reset_counters() end)

    # --- House-income in-flight register ---
    safe_call(fn -> Minted.Mint.House.Store.clear() end)

    :ok
  end

  defp safe_clear(module) do
    module.clear()
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  defp safe_call(fun) do
    fun.()
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  defp safe_ets_clear(table) do
    if :ets.whereis(table) != :undefined do
      :ets.delete_all_objects(table)
    end
  rescue
    _ -> :ok
  end
end
