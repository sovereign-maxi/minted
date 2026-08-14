defmodule Minted.Lightning.Facade do
  @moduledoc false

  alias Minted.Lightning.{Executor, Manager, Monitor}

  @doc "Returns the current Lightning liquidity status."
  @spec liquidity_status() :: {non_neg_integer(), atom()}
  def liquidity_status do
    Monitor.get_status()
  end

  @doc """
  Returns the current inbound liquidity in sats, clamped to >= 0.
  Used by Mint.Fees to detect when a deposit will exceed available
  inbound capacity and require a splice.
  """
  @spec inbound_liquidity() :: non_neg_integer()
  def inbound_liquidity do
    max(Monitor.get_inbound_liquidity(), 0)
  rescue
    _ -> 0
  catch
    :exit, _ -> 0
  end

  @doc """
  Returns `{:ok, sats}` when liquidity data is available, `:unknown`
  otherwise. Fee-pricing callers use this to distinguish "no inbound
  liquidity" from "no data" — the two need opposite fee treatment.
  """
  @spec inbound_liquidity_checked() :: {:ok, non_neg_integer()} | :unknown
  def inbound_liquidity_checked do
    Monitor.inbound_liquidity()
  rescue
    _ -> :unknown
  catch
    :exit, _ -> :unknown
  end

  @doc """
  Creates a new Lightning invoice via the Phoenixd gateway. Returns the
  full invoice struct on success. Optional keyword arguments (e.g.
  `:quote_id`) are passed through to the underlying manager for
  correlation tracking.
  """
  @spec create_invoice(pos_integer(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def create_invoice(amount_sats, description, opts \\ []) do
    Manager.create_invoice(amount_sats, description, opts)
  end

  @doc """
  Parses a bolt11 invoice string and returns the amount in sats. Wraps
  the bolt11 parser so callers in the web layer never have to name the
  internal parser module. Returns a `non_neg_integer` — a zero-amount
  result is valid for amount-less invoices (`lnbc1p...`) and must be
  handled by the caller as a distinct case from a parse error.
  """
  @spec parse_bolt11_amount(String.t()) :: {:ok, non_neg_integer()} | {:error, atom()}
  def parse_bolt11_amount(bolt11), do: FireBird.Bolt11.parse_amount(bolt11)

  @doc """
  Extracts the invoice's 32-byte Lightning payment hash (the `p`
  tagged field) from a bolt11 string. Callers use this for outbound-
  payment reconciliation — the payment hash is the identifier the
  Lightning network keys by, and phoenixd's
  `/payments/outgoingbyhash/{paymentHash}` endpoint accepts it
  regardless of any locally-generated correlation id.
  """
  @spec parse_bolt11_payment_hash(String.t()) :: {:ok, binary()} | {:error, atom()}
  def parse_bolt11_payment_hash(bolt11), do: FireBird.Bolt11.payment_hash(bolt11)

  @doc """
  Executes an outbound Lightning payment and blocks until settlement
  or timeout. Takes a pre-built `Minted.Lightning.Payment` struct
  (which is part of the Lightning domain's published language for
  outbound payment requests).
  """
  @spec execute_payment_and_await(map()) :: {:ok, map()} | {:error, term()}
  def execute_payment_and_await(payment), do: Executor.execute_and_await(payment)

  @doc "Estimates the Lightning routing fee for a withdrawal amount."
  @spec routing_fee_estimate(non_neg_integer()) :: non_neg_integer()
  def routing_fee_estimate(amount_sats), do: Minted.Lightning.Fees.withdrawal_fee(amount_sats)

  @doc "Pings Phoenixd to check if it's reachable."
  @spec health_check() :: :ok | {:error, term()}
  def health_check do
    {mod, config} = Minted.Lightning.Adapters.Client.client_tuple()
    mod.health_check(config)
  end
end
