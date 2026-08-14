defmodule Minted.Lightning.Fees do
  @moduledoc """
  Fee calculation bridging application config to `FireBird.Fees`.

  The raw `calculate/2` function preserves the original PPM-only signature.
  `deposit_fee/1` and `withdrawal_fee/1` read config and delegate with
  min/max clamping options.
  """

  @max_amount_sats 2_100_000_000_000_000

  @doc """
  Calculates the fee for a given amount and PPM rate.

  Returns 0 for zero amounts. Raises on negative inputs.
  """
  @spec calculate(non_neg_integer(), non_neg_integer()) :: non_neg_integer()
  def calculate(0, _ppm_rate), do: 0
  def calculate(_amount_sats, 0), do: 0

  def calculate(amount_sats, _ppm_rate)
      when is_integer(amount_sats) and amount_sats > @max_amount_sats do
    raise ArgumentError, "amount exceeds maximum of #{@max_amount_sats} sats"
  end

  def calculate(amount_sats, ppm_rate)
      when is_integer(amount_sats) and amount_sats > 0 and
             is_integer(ppm_rate) and ppm_rate > 0 do
    FireBird.Fees.calculate(amount_sats,
      fee_ppm: ppm_rate,
      fee_min_sats: 0,
      fee_max_sats: @max_amount_sats
    )
  end

  @doc """
  Calculates the deposit fee using the configured PPM rate.

  When the deposit would exceed available inbound liquidity (triggering a
  PhoenixD splice), the fee is bumped to cover ACINQ's ~1% liquidity cost
  plus mining fees. Configured via `:splice_fee_ppm` (default 12_000 = 1.2%).
  """
  @spec deposit_fee(non_neg_integer()) :: non_neg_integer()
  def deposit_fee(0), do: 0

  def deposit_fee(amount_sats) when is_integer(amount_sats) and amount_sats > 0 do
    config = lightning_config()
    base_ppm = Keyword.get(config, :deposit_fee_ppm, Keyword.get(config, :fee_ppm, 1_000))
    splice_ppm = Keyword.get(config, :splice_fee_ppm, 12_000)
    min_fee = Keyword.get(config, :fee_min_sats, 1)
    max_fee = Keyword.get(config, :fee_max_sats, 100_000)

    ppm = effective_deposit_ppm(amount_sats, base_ppm, splice_ppm)

    FireBird.Fees.calculate(amount_sats,
      fee_ppm: ppm,
      fee_min_sats: min_fee,
      fee_max_sats: max_fee
    )
  end

  defp effective_deposit_ppm(amount_sats, base_ppm, splice_ppm) do
    case Minted.Lightning.Monitor.inbound_liquidity() do
      :unknown ->
        # No monitor data — charge the base rate. The charge-point
        # calculator (Mint.Fees) meters blind pricing.
        base_ppm

      {:ok, inbound} ->
        if inbound > 0 and amount_sats > inbound do
          max(base_ppm, splice_ppm)
        else
          base_ppm
        end
    end
  end

  @doc """
  Estimates the withdrawal fee (routing cost passed through to user).

  No operator margin — that's collected at deposit. This is purely
  the estimated Lightning routing fee so the user knows the total
  cost before confirming.
  """
  @spec withdrawal_fee(non_neg_integer()) :: non_neg_integer()
  def withdrawal_fee(0), do: 0

  def withdrawal_fee(amount_sats) when is_integer(amount_sats) and amount_sats > 0 do
    config = lightning_config()
    ppm = Keyword.get(config, :routing_fee_estimate_ppm, 3_000)
    min_fee = Keyword.get(config, :routing_fee_min_sats, 2)

    max(min_fee, div(amount_sats * ppm, 1_000_000))
  end

  defp lightning_config do
    Application.get_env(:minted, :lightning, [])
  end
end
