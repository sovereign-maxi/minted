defmodule Minted.Lightning.Adapters.Breakered do
  @moduledoc """
  `FireBird.Client` implementation wrapping `FireBird.HTTP`.

  The money-moving `pay_invoice/5` call routes through the circuit
  breaker; everything else delegates directly. Read-only call sites
  (invoice creation, status lookups) already wrap themselves via
  `Breaker.call/2` at the Manager/Resolver level — wrapping them here
  too would double-record every outcome.
  """

  alias Minted.Lightning.Breaker

  @doc "Pays a bolt11 invoice through the circuit breaker."
  def pay_invoice(config, bolt11, amount_sats, description, fee_limit_sats) do
    Breaker.call(:phoenixd, fn ->
      FireBird.HTTP.pay_invoice(config, bolt11, amount_sats, description, fee_limit_sats)
    end)
  end

  defdelegate create_invoice(config, amount_sats, description, expiry_seconds), to: FireBird.HTTP
  defdelegate get_balance(config), to: FireBird.HTTP
  defdelegate get_incoming_payment(config, payment_hash), to: FireBird.HTTP
  defdelegate get_info(config), to: FireBird.HTTP
  defdelegate health_check(config), to: FireBird.HTTP
  defdelegate get_outgoing_payment(config, payment_id), to: FireBird.HTTP
  defdelegate get_outgoing_payment_by_hash(config, payment_hash), to: FireBird.HTTP
  defdelegate send_onchain(config, address, amount_sats, feerate_sat_byte), to: FireBird.HTTP
end
