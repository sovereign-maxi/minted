defmodule Minted.Identity.Escalation do
  @moduledoc """
  Event handler that subscribes to `DoubleSpendRejected` events and applies
  escalating rate limit penalties to offending circuits.

  When a double-spend attempt is detected, the handler applies a stricter rate
  limit multiplier to the offending circuit. Multiple attempts stack:
  3x -> 9x -> 27x -> 81x (capped). Each new event resets the cooldown timer.

  Escalation state is stored in ETS (no disk persistence) for privacy preservation.
  """

  use GenServer

  alias Minted.Events.EventBus
  alias Minted.Events.Identity, as: IdentityEvents

  require Logger

  alias Seer.RateLimiter

  @escalation_table Minted.Identity.Escalation
  @base_multiplier Application.compile_env(
                     :minted,
                     [:identity, :escalation_base_multiplier],
                     3
                   )
  @max_multiplier Application.compile_env(
                    :minted,
                    [:identity, :escalation_max_multiplier],
                    81
                  )
  @cooldown_seconds Application.compile_env(
                      :minted,
                      [:identity, :escalation_cooldown_seconds],
                      900
                    )

  # --- Public API ---

  @doc """
  Starts the Escalation GenServer.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Records a double-spend attempt for a circuit_id_hash.
  Applies an escalated rate limit multiplier.
  """
  @spec record(binary()) :: :ok
  def record(circuit_id_hash) do
    GenServer.call(__MODULE__, {:record, circuit_id_hash})
  end

  @doc """
  Checks if a circuit_id_hash is currently under escalation.
  Returns `{:ok, multiplier}` if escalated, or `:ok` if not.
  """
  @spec status(binary()) :: {:escalated, pos_integer()} | :ok
  def status(circuit_id_hash) do
    now = System.monotonic_time(:second)

    case :ets.lookup(@escalation_table, circuit_id_hash) do
      [{^circuit_id_hash, count, _multiplier, expires_at}] when expires_at > now ->
        multiplier = compute_multiplier(count)
        {:escalated, multiplier}

      _ ->
        :ok
    end
  end

  @doc """
  Checks if a circuit_id_hash has been banned (reached max multiplier).
  """
  @spec banned?(binary()) :: boolean()
  def banned?(circuit_id_hash) do
    case status(circuit_id_hash) do
      {:escalated, multiplier} -> multiplier >= @max_multiplier
      :ok -> false
    end
  end

  @doc """
  Resets escalation state for a circuit_id_hash.
  Routes through GenServer to avoid racing with concurrent `do_record/1` calls.
  """
  @spec reset(binary()) :: :ok
  def reset(circuit_id_hash) do
    GenServer.call(__MODULE__, {:reset, circuit_id_hash})
  end

  @doc """
  Cleans up expired escalation entries. Called periodically.
  """
  @spec cleanup() :: :ok
  def cleanup do
    now = System.monotonic_time(:second)

    :ets.select_delete(@escalation_table, [
      {{:_, :_, :_, :"$1"}, [{:<, :"$1", now}], [true]}
    ])

    :ok
  end

  # --- GenServer Callbacks ---

  @impl true
  def init(_opts) do
    Process.flag(:trap_exit, true)

    :ets.new(@escalation_table, [:set, :public, :named_table, {:write_concurrency, true}])

    {:ok, %{}}
  end

  @impl true
  def handle_call({:record, circuit_id_hash}, _from, state) do
    do_record(circuit_id_hash)
    {:reply, :ok, state}
  end

  def handle_call({:reset, circuit_id_hash}, _from, state) do
    :ets.delete(@escalation_table, circuit_id_hash)

    RateLimiter.apply_multiplier(
      circuit_id_hash,
      1,
      System.monotonic_time(:second) + 1
    )

    {:reply, :ok, state}
  end

  # DoubleSpendDetected DOES NOT drive escalation any more. It was
  # published under the secret_hash and the rate limiter keys
  # multipliers under circuit_id_hash — the two never lined up, so
  # the subscription was silently dead. Rate-limit escalation now
  # happens explicitly at the request boundary
  # (`MintedWeb.FallbackController` calls `record/1` with the conn's
  # `circuit_id_hash`), which is the only layer that knows both that
  # the request produced a double-spend response AND the identifier
  # the rate limiter will actually look up.

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, _state), do: :ok

  # --- Private Functions ---

  defp do_record(circuit_id_hash) do
    now = System.monotonic_time(:second)
    expires_at = now + @cooldown_seconds

    count =
      case :ets.lookup(@escalation_table, circuit_id_hash) do
        [{^circuit_id_hash, prev_count, _mult, prev_expires}] when prev_expires > now ->
          prev_count + 1

        _ ->
          1
      end

    multiplier = compute_multiplier(count)
    :ets.insert(@escalation_table, {circuit_id_hash, count, multiplier, expires_at})

    # Apply the multiplier to the rate limiter.
    RateLimiter.apply_multiplier(circuit_id_hash, multiplier, expires_at)

    Logger.warning(
      "Escalation: circuit=#{Base.encode16(circuit_id_hash, case: :lower) |> String.slice(0, 16)}... multiplier=#{multiplier}x cooldown=#{@cooldown_seconds}s"
    )

    try do
      EventBus.publish(%IdentityEvents.RateLimitEscalated{
        circuit_id_hash: circuit_id_hash,
        multiplier: multiplier,
        cooldown_seconds: @cooldown_seconds,
        timestamp: DateTime.utc_now()
      })
    rescue
      ArgumentError -> :ok
    end
  end

  defp compute_multiplier(count) do
    # 3^1 = 3, 3^2 = 9, 3^3 = 27, 3^4 = 81
    raw = trunc(:math.pow(@base_multiplier, count))
    min(@max_multiplier, raw)
  end
end
