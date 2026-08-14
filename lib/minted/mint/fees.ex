defmodule Minted.Mint.Fees do
  @moduledoc """
  Fee policy for deposit and withdrawal operations.

  Fees are computed as parts-per-million (ppm) of the transaction amount,
  always rounded up to the nearest sat via ceiling division.
  """

  require Logger

  @enforce_keys [:deposit_ppm, :withdrawal_ppm, :min_fee, :max_fee]
  defstruct [
    :deposit_ppm,
    :withdrawal_ppm,
    :min_fee,
    :max_fee
  ]

  @type t :: %__MODULE__{
          deposit_ppm: non_neg_integer(),
          withdrawal_ppm: non_neg_integer(),
          min_fee: non_neg_integer(),
          max_fee: pos_integer()
        }

  # 1,000,000 ppm = 100% fee (absolute ceiling)
  @max_ppm 1_000_000
  # 21M BTC in sats — effectively no cap when fee_max_sats is not configured
  @max_amount_sats 2_100_000_000_000_000

  @spec from_config() :: t()
  def from_config do
    ln = Application.get_env(:minted, :lightning, [])

    deposit_ppm = Keyword.get(ln, :deposit_fee_ppm, Keyword.get(ln, :fee_ppm, 1_000))
    withdrawal_ppm = Keyword.get(ln, :withdrawal_fee_ppm, Keyword.get(ln, :fee_ppm, 1_000))

    deposit_ppm = clamp_ppm(deposit_ppm, :deposit)
    withdrawal_ppm = clamp_ppm(withdrawal_ppm, :withdrawal)

    %__MODULE__{
      deposit_ppm: deposit_ppm,
      withdrawal_ppm: withdrawal_ppm,
      min_fee: Keyword.get(ln, :fee_min_sats, 1),
      max_fee: Keyword.get(ln, :fee_max_sats, @max_amount_sats)
    }
  end

  defp clamp_ppm(ppm, _type) when is_integer(ppm) and ppm >= 0 and ppm <= @max_ppm, do: ppm

  defp clamp_ppm(ppm, type) when is_integer(ppm) and ppm < 0 do
    Logger.warning("Fees: negative ppm clamped to 0, type=#{type}, ppm=#{ppm}")
    0
  end

  defp clamp_ppm(ppm, type) when is_integer(ppm) do
    Logger.warning("Fees: ppm exceeds max, type=#{type}, ppm=#{ppm}, max=#{@max_ppm}")
    @max_ppm
  end

  defp clamp_ppm(_ppm, type) do
    Logger.warning("Fees: non-integer ppm defaulting to 0, type=#{type}")
    0
  end

  @type fee_type :: :deposit | :withdrawal

  @spec calculate(t(), non_neg_integer(), fee_type()) :: {:ok, non_neg_integer()}
  def calculate(_schedule, 0, _type), do: {:ok, 0}

  def calculate(%__MODULE__{} = schedule, amount, type) when is_integer(amount) and amount > 0 do
    {ppm, min_f, max_f} = fee_params(schedule, type, amount)

    ppm = min(max(ppm, 0), @max_ppm)

    if ppm == 0 do
      {:ok, 0}
    else
      fee = ceil_div(amount * ppm, 1_000_000)
      fee = fee |> max(min_f) |> min(max_f)
      {:ok, fee}
    end
  end

  defp fee_params(schedule, :deposit, amount) do
    {effective_deposit_ppm(schedule.deposit_ppm, amount), schedule.min_fee, schedule.max_fee}
  end

  defp fee_params(schedule, :withdrawal, _amount) do
    {schedule.withdrawal_ppm, schedule.min_fee, schedule.max_fee}
  end

  # When a deposit exceeds available inbound liquidity, PhoenixD will splice
  # a new channel at ~1% + mining fees. Bump the fee to cover this cost.
  defp effective_deposit_ppm(base_ppm, amount) do
    config = Application.get_env(:minted, :lightning, [])
    splice_ppm = Keyword.get(config, :splice_fee_ppm, 12_000)

    case Minted.Lightning.Facade.inbound_liquidity_checked() do
      :unknown ->
        # No monitor data: charge the base rate and meter the blind
        # pricing. Bumping every deposit to splice rate during a
        # monitor wobble would overcharge honest users; the residual
        # undercharge risk is accepted and observed here instead.
        :telemetry.execute([:minted, :mint, :fees, :blind_pricing], %{count: 1}, %{})
        base_ppm

      {:ok, inbound} ->
        if inbound > 0 and amount > inbound do
          max(base_ppm, splice_ppm)
        else
          base_ppm
        end
    end
  end

  defp ceil_div(0, _denominator), do: 0
  defp ceil_div(numerator, denominator), do: div(numerator + denominator - 1, denominator)
end
