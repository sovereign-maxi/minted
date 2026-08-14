defmodule Minted.Mint.House.Console do
  @moduledoc """
  Operator-facing iex helpers for house-income operations.

  All mutating operations are deliberately iex-only — there is no
  HTTP endpoint, no LiveView form. Operator presence at a terminal
  is itself a security control: a stolen browser session cannot
  drain house income, no matter what state the admin dashboard is
  in.

  ## Usage

  Connect to a running node:

      $ iex --remsh minted@node

  Then:

      iex> Minted.Mint.House.Console.status()
      iex> Minted.Mint.House.Console.withdraw(1_000_000, "lnbc1m1p...")

  ## Output

  Functions that print return `:ok`; functions that execute an
  action return the result tuple from the underlying Facade.
  """

  alias Minted.Format
  alias Minted.Lightning.Facade, as: LightningFacade
  alias Minted.Lightning.Payment
  alias Minted.Mint.House.Facade

  # --- Read helpers ---

  @doc """
  Prints a formatted snapshot of the house-income ledger. Shows
  earned / drawn / in-flight / withdrawable / max single request.
  Returns `:ok`.
  """
  @spec status() :: :ok
  def status do
    earned = Facade.earned()
    drawn = Facade.drawn()
    in_flight = Facade.in_flight()
    withdrawable = Facade.withdrawable()
    max_single = Facade.max_single_request()

    IO.puts("""

    House Income
    ────────────
      Earned:              #{format_sats(earned)}
      Drawn:               #{format_sats(drawn)}
      In-flight:           #{format_sats(in_flight)}
      Withdrawable:        #{format_sats(withdrawable)}
      Max single request:  #{format_sats(max_single)}  (half-cap rule)
    """)

    :ok
  end

  # --- Withdrawal ---

  @doc """
  Executes a house-income withdrawal end-to-end from the operator
  console: registers the request through the Facade (guard-checked
  against withdrawable + half-cap + minimum), pays the invoice via
  phoenixd, and marks the request as completed or rejected based
  on payment outcome.

  This is the ONLY sanctioned withdrawal path. Admin dashboard is
  read-only. LiveView forms don't exist.

  ## Arguments

    * `amount_sats` — positive integer, must be ≤ half of withdrawable
    * `bolt11`     — destination invoice, decoded via `LightningFacade`

  ## Returns

    * `{:ok, %{request_id, amount_sats, fee_sats}}` on success
    * `{:error, reason}` on any failure — withdrawal is REJECTED
      via the Facade so withdrawable capacity is restored
  """
  @spec withdraw(pos_integer(), String.t()) ::
          {:ok, %{request_id: String.t(), amount_sats: pos_integer(), fee_sats: non_neg_integer()}}
          | {:error, term()}
  def withdraw(amount_sats, bolt11)
      when is_integer(amount_sats) and amount_sats > 0 and is_binary(bolt11) do
    IO.puts("""

    House Withdrawal
    ────────────────
      Amount:      #{format_sats(amount_sats)}
      Invoice:     #{truncate(bolt11)}
    """)

    with {:ok, event} <- register(amount_sats, bolt11),
         {:ok, %{fee_sats: fee_sats}} <- pay_invoice(event.request_id, bolt11, amount_sats) do
      complete(event.request_id, fee_sats)
    else
      {:error, {stage, reason}} ->
        IO.puts("Withdrawal failed at #{stage}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # --- Private stages ---

  defp register(amount_sats, bolt11) do
    IO.write("  Registering withdrawal request... ")

    case Facade.request_withdrawal(amount_sats, bolt11) do
      {:ok, event} ->
        IO.puts("OK (#{event.request_id})")
        {:ok, event}

      {:error, reason} ->
        IO.puts("REJECTED (#{reason})")
        {:error, {:register, reason}}
    end
  end

  defp pay_invoice(request_id, bolt11, amount_sats) do
    IO.write("  Paying invoice via phoenixd...      ")
    fee_limit = LightningFacade.routing_fee_estimate(amount_sats)
    payment = Payment.new(bolt11: bolt11, amount_sats: amount_sats, fee_limit_sats: fee_limit)

    case LightningFacade.execute_payment_and_await(payment) do
      {:ok, result} ->
        # Executor returns `:routing_fee` (see executor.ex — the map
        # key is a Payment field, not a JSON key). The old
        # `:routing_fee_sat` read was silently absent so console
        # always reported 0 sats regardless of actual routing cost.
        fee_sats = Map.get(result, :routing_fee, 0) || 0
        IO.puts("SENT (fee: #{fee_sats} sats)")
        {:ok, %{fee_sats: fee_sats}}

      {:error, :settlement_timeout} ->
        hold_withdrawal(request_id, :settlement_timeout)

      {:error, {:settlement_unknown, reason}} ->
        hold_withdrawal(request_id, {:settlement_unknown, reason})

      {:error, reason} ->
        # Definitive failure — reject before returning so withdrawable
        # capacity is restored immediately.
        Facade.reject_withdrawal(request_id, classify_ln_error(reason))
        IO.puts("FAILED (#{inspect(reason)})")
        {:error, {:payment, reason}}
    end
  end

  # Ambiguous outcome: the sats MAY have left the channel. Rejecting
  # here would restore withdrawable capacity that no longer exists —
  # later withdrawals would dip into user-backed reserves. Keep the
  # request in-flight until the operator reconciles against phoenixd.
  defp hold_withdrawal(request_id, reason) do
    IO.puts("""
    OUTCOME UNKNOWN (#{inspect(reason)})
      The request stays IN-FLIGHT — withdrawable capacity is NOT restored.
      Reconcile against phoenixd, then either:
        Minted.Mint.House.Facade.complete_withdrawal(#{inspect(request_id)}, fee_sats)
        Minted.Mint.House.Facade.reject_withdrawal(#{inspect(request_id)}, :payment_failed)
    """)

    {:error, {:payment, :settlement_unknown}}
  end

  defp complete(request_id, fee_sats) do
    IO.write("  Marking withdrawal complete...      ")
    :ok = Facade.complete_withdrawal(request_id, fee_sats)
    IO.puts("OK")
    IO.puts("")

    {:ok, %{request_id: request_id, fee_sats: fee_sats}}
  end

  # --- Helpers ---

  defp format_sats(sats) when is_integer(sats), do: "#{Format.format_sats(sats)} sats"

  defp truncate(str) when byte_size(str) > 40 do
    prefix = binary_part(str, 0, 16)
    suffix = binary_part(str, byte_size(str) - 8, 8)
    "#{prefix}…#{suffix}"
  end

  defp truncate(str), do: str

  # Best-effort mapping from LN errors to the Facade's rejection
  # reasons. When phoenixd returns something we can't classify,
  # fall through to :payment_failed so the audit trail still
  # tags a real cause instead of :unknown.
  defp classify_ln_error(:invalid_bolt11), do: :invalid_invoice
  defp classify_ln_error(:bolt11_amount_mismatch), do: :invalid_invoice
  defp classify_ln_error(_other), do: :payment_failed
end
