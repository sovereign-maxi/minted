defmodule Minted.Telemetry.Alerts.Rule do
  @moduledoc """
  Alert rule with condition function and state machine lifecycle.

  Lifecycle: `:ok` → `:pending` → `:firing` → `:resolving` → `:resolved` → `:ok`

  The `for_duration` field controls the debounce delay between
  `:pending` and `:firing` states to prevent flapping on fire.

  The `resolve_after` field controls how many consecutive OK evaluations
  are required before transitioning from `:firing` to `:resolved`,
  preventing premature resolution on transient recoveries.
  """

  require Logger

  @enforce_keys [:name, :domain, :condition, :severity]
  defstruct [
    :name,
    :domain,
    :condition,
    :severity,
    :fired_at,
    :resolved_at,
    :pending_since,
    :reason,
    state: :ok,
    for_duration: 0,
    resolve_after: 3,
    ok_count: 0
  ]

  @type severity :: :info | :warning | :critical | :emergency
  @type state :: :ok | :pending | :firing | :resolving | :resolved

  @type t :: %__MODULE__{
          name: atom(),
          condition: (-> :ok | {:alert, String.t()}),
          severity: severity(),
          state: state(),
          for_duration: non_neg_integer(),
          resolve_after: non_neg_integer(),
          ok_count: non_neg_integer(),
          pending_since: integer() | nil,
          fired_at: DateTime.t() | nil,
          resolved_at: DateTime.t() | nil,
          reason: String.t() | nil
        }

  @doc "Evaluates the rule condition and transitions state accordingly."
  @spec evaluate(t()) :: t()
  def evaluate(%__MODULE__{} = rule) do
    case safe_eval(rule.condition) do
      :ok -> handle_ok(rule)
      {:alert, reason} -> handle_alert(rule, reason)
    end
  end

  @doc "Returns true if the rule is currently firing."
  @spec firing?(t()) :: boolean()
  def firing?(%__MODULE__{state: :firing}), do: true
  def firing?(%__MODULE__{state: :resolving}), do: true
  def firing?(_), do: false

  # --- Private ---

  defp safe_eval(condition) do
    condition.()
  rescue
    e ->
      Logger.warning("Rule: safe_eval failed: #{inspect(e)}")
      :ok
  end

  # :ok state — no change needed
  defp handle_ok(%{state: :ok} = rule), do: rule

  # :pending → :ok — condition cleared before debounce, cancel
  defp handle_ok(%{state: :pending} = rule),
    do: %{rule | state: :ok, pending_since: nil, reason: nil, ok_count: 0}

  # :firing → :resolving — start counting consecutive OK evaluations
  defp handle_ok(%{state: :firing} = rule) do
    new_count = rule.ok_count + 1

    if rule.resolve_after == 0 or new_count >= rule.resolve_after do
      %{rule | state: :resolved, resolved_at: DateTime.utc_now(), ok_count: 0}
    else
      %{rule | state: :resolving, ok_count: new_count}
    end
  end

  # :resolving — keep counting consecutive OKs
  defp handle_ok(%{state: :resolving} = rule) do
    new_count = rule.ok_count + 1

    if new_count >= rule.resolve_after do
      %{rule | state: :resolved, resolved_at: DateTime.utc_now(), ok_count: 0}
    else
      %{rule | ok_count: new_count}
    end
  end

  # :resolved → :ok — complete resolution cycle
  defp handle_ok(%{state: :resolved} = rule), do: %{rule | state: :ok, ok_count: 0}

  # :ok → :pending or :firing — new alert detected
  defp handle_alert(%{state: :ok} = rule, reason) do
    if rule.for_duration == 0 do
      %{rule | state: :firing, fired_at: DateTime.utc_now(), reason: reason, ok_count: 0}
    else
      %{
        rule
        | state: :pending,
          pending_since: System.monotonic_time(:millisecond),
          reason: reason,
          ok_count: 0
      }
    end
  end

  # :pending — waiting for debounce timer
  defp handle_alert(%{state: :pending} = rule, reason) do
    elapsed = System.monotonic_time(:millisecond) - (rule.pending_since || 0)

    if elapsed >= rule.for_duration do
      %{rule | state: :firing, fired_at: DateTime.utc_now(), reason: reason, ok_count: 0}
    else
      %{rule | reason: reason}
    end
  end

  # :firing — still alerting, reset OK counter
  defp handle_alert(%{state: :firing} = rule, reason) do
    %{rule | reason: reason, ok_count: 0}
  end

  # :resolving — alert returned while resolving, back to firing
  defp handle_alert(%{state: :resolving} = rule, reason) do
    %{rule | state: :firing, reason: reason, ok_count: 0}
  end

  # :resolved — alert re-appeared after resolution, re-fire
  defp handle_alert(%{state: :resolved} = rule, reason) do
    %{rule | state: :firing, fired_at: DateTime.utc_now(), reason: reason, ok_count: 0}
  end
end
