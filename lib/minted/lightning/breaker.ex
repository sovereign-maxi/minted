defmodule Minted.Lightning.Breaker do
  @moduledoc """
  Circuit breaker protecting outbound Phoenixd HTTP calls from cascading failures.

  Tracks failures per named key (e.g. `:phoenixd`). After `@failure_threshold`
  consecutive failures the circuit opens and subsequent calls return
  `{:error, :circuit_open}` immediately without touching the network.

  After `@reset_timeout_ms` the circuit moves to `:half_open` and allows one
  probe call. A successful probe closes the circuit; another failure re-opens it.
  """

  use GenServer

  require Logger

  @failure_threshold 5
  @reset_timeout_ms 30_000

  # --- Public API ---

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Executes `fun/0` if the circuit for `key` is closed or half-open.

  Records success/failure automatically based on whether `fun` returns
  `{:ok, _}` or `{:error, _}`. Returns `{:error, :circuit_open}` without
  calling `fun` if the circuit is open.
  """
  @spec call(atom(), (-> {:ok, any()} | {:error, any()})) :: {:ok, any()} | {:error, any()}
  def call(key, fun) when is_atom(key) and is_function(fun, 0) do
    case GenServer.call(__MODULE__, {:check, key}) do
      :allow ->
        result = fun.()

        case result do
          {:ok, _} -> GenServer.cast(__MODULE__, {:success, key})
          {:error, _} -> GenServer.cast(__MODULE__, {:failure, key})
        end

        result

      :reject ->
        {:error, :circuit_open}
    end
  catch
    # Process not running (supervisor restart window). Fail closed:
    # executing unprotected would defeat the breaker's purpose during
    # exactly the brown-outs it exists for. The payment/call was never
    # attempted, so callers may safely treat this as definitive.
    :exit, {:noproc, _} -> {:error, :breaker_unavailable}
  end

  @doc "Resets all circuit state. Intended for use in tests."
  @spec clear() :: :ok
  def clear do
    GenServer.call(__MODULE__, :clear)
  end

  # --- GenServer callbacks ---

  @impl true
  def init(_opts) do
    {:ok, %{}}
  end

  @impl true
  def handle_call(:clear, _from, _state) do
    {:reply, :ok, %{}}
  end

  @impl true
  def handle_call({:check, key}, _from, state) do
    circuit = Map.get(state, key, default_circuit())
    now = System.monotonic_time(:millisecond)
    {reply, new_circuit} = do_check(circuit, now, key)
    {:reply, reply, Map.put(state, key, new_circuit)}
  end

  @impl true
  def handle_cast({:success, key}, state) do
    circuit = Map.get(state, key, default_circuit())

    new_circuit =
      case circuit.state do
        :probing ->
          Logger.info("Breaker: closed after successful probe, circuit=#{key}")
          %{circuit | state: :closed, failures: 0, opened_at: nil}

        :half_open ->
          Logger.info("Breaker: closed after successful probe, circuit=#{key}")
          %{circuit | state: :closed, failures: 0, opened_at: nil}

        :open ->
          # Stale success — the request started BEFORE the circuit
          # opened. Closing now would skip the reset timeout and
          # hammer a struggling node.
          circuit

        :closed ->
          %{circuit | failures: 0}
      end

    {:noreply, Map.put(state, key, new_circuit)}
  end

  def handle_cast({:failure, key}, state) do
    circuit = Map.get(state, key, default_circuit())
    failures = circuit.failures + 1

    new_circuit =
      if failures >= @failure_threshold do
        if circuit.state != :open do
          Logger.error(
            "Breaker: opened, circuit=#{key}, failures=#{failures} — " <>
              "Phoenixd calls will fast-fail for #{div(@reset_timeout_ms, 1000)}s"
          )
        end

        %{circuit | state: :open, failures: failures, opened_at: System.monotonic_time(:millisecond)}
      else
        %{circuit | state: :closed, failures: failures}
      end

    {:noreply, Map.put(state, key, new_circuit)}
  end

  # --- Private ---

  defp do_check(%{state: :closed} = circuit, _now, _key), do: {:allow, circuit}

  defp do_check(%{state: :open, opened_at: opened_at} = circuit, now, key) do
    if now - opened_at >= @reset_timeout_ms do
      Logger.info("Breaker: transitioning to half-open, circuit=#{key}")
      # Transition directly to :probing so only one request gets through.
      {:allow, %{circuit | state: :probing}}
    else
      {:reject, circuit}
    end
  end

  # Only one probe at a time — reject concurrent probes.
  defp do_check(%{state: :probing} = circuit, _now, _key), do: {:reject, circuit}
  defp do_check(%{state: :half_open} = circuit, _now, _key), do: {:allow, circuit}

  defp default_circuit, do: %{state: :closed, failures: 0, opened_at: nil}
end
