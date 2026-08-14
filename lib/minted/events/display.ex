defprotocol Minted.Events.Display do
  @moduledoc """
  Protocol for self-describing events.

  Each event knows its bounded context (domain), human label, severity,
  and detail string. Consumers render these directly without interpreting
  event types.
  """

  @doc ~S(Bounded context name, e.g. "Mint", "Lightning", "Reserves".)
  @spec domain(t) :: String.t()
  def domain(event)

  @doc ~S(Human-readable event label, e.g. "Tokens Minted", "Peer Down".)
  @spec label(t) :: String.t()
  def label(event)

  @doc "Severity atom: :info, :warning, :critical, :emergency."
  @spec severity(t) :: :info | :warning | :critical | :emergency
  def severity(event)

  @doc "Short detail string for extra context (amounts, IDs). Empty string if none."
  @spec detail(t) :: String.t()
  def detail(event)
end

# --- Mint context ---

defimpl Minted.Events.Display, for: Minted.Events.Mint.TokensMinted do
  def domain(_), do: "Mint"
  def label(_), do: "Tokens Minted"
  def severity(_), do: :info
  def detail(e), do: "amount=#{e.amount} sats"
end

defimpl Minted.Events.Display, for: Minted.Events.Mint.TokensBurned do
  def domain(_), do: "Mint"
  def label(_), do: "Tokens Burned"
  def severity(_), do: :info
  def detail(e), do: "amount=#{e.amount} sats"
end

defimpl Minted.Events.Display, for: Minted.Events.Mint.TokensSwapped do
  def domain(_), do: "Mint"
  def label(_), do: "Tokens Swapped"
  def severity(_), do: :info
  def detail(e), do: "amount=#{e.amount} sats"
end

defimpl Minted.Events.Display, for: Minted.Events.Mint.FeesCollected do
  def domain(_), do: "Mint"
  def label(_), do: "Fees Collected"
  def severity(_), do: :info
  def detail(e), do: "amount=#{e.amount} sats"
end

defimpl Minted.Events.Display, for: Minted.Events.Mint.DoubleSpendDetected do
  def domain(_), do: "Mint"
  def label(_), do: "Double Spend Detected"
  def severity(_), do: :critical
  def detail(e), do: "keyset=#{String.slice(e.keyset_id, 0..7)}"
end

# --- Lightning context ---

defimpl Minted.Events.Display, for: Minted.Events.Lightning.InvoicePaid do
  def domain(_), do: "Lightning"
  def label(_), do: "Invoice Paid"
  def severity(_), do: :info
  def detail(e), do: if(e.quote_id, do: "quote=#{e.quote_id}", else: "")
end

defimpl Minted.Events.Display, for: Minted.Events.Lightning.PaymentSent do
  def domain(_), do: "Lightning"
  def label(_), do: "Payment Sent"
  def severity(_), do: :info
  def detail(e), do: "amount=#{e.amount_sats} sats"
end

defimpl Minted.Events.Display, for: Minted.Events.Lightning.PaymentFailed do
  def domain(_), do: "Lightning"
  def label(_), do: "Payment Failed"
  def severity(_), do: :warning
  def detail(e), do: "error=#{format_error(e.error)}"

  defp format_error(error) when is_atom(error), do: error
  defp format_error(error) when is_binary(error), do: error
  defp format_error(error), do: inspect(error)
end

defimpl Minted.Events.Display, for: Minted.Events.Lightning.LiquidityLow do
  def domain(_), do: "Lightning"
  def label(_), do: "Liquidity Low"
  def severity(_), do: :warning
  def detail(e), do: "balance=#{e.balance_sats} sats"
end

defimpl Minted.Events.Display, for: Minted.Events.Lightning.LiquidityCritical do
  def domain(_), do: "Lightning"
  def label(_), do: "Liquidity Critical"
  def severity(_), do: :critical
  def detail(e), do: "balance=#{e.balance_sats} sats"
end

defimpl Minted.Events.Display, for: Minted.Events.Lightning.LiquidityRecovered do
  def domain(_), do: "Lightning"
  def label(_), do: "Liquidity Recovered"
  def severity(_), do: :info
  def detail(e), do: "balance=#{e.balance_sats} sats"
end

defimpl Minted.Events.Display, for: Minted.Events.Lightning.PaymentExhausted do
  def domain(_), do: "Lightning"
  def label(_), do: "Payment Exhausted"
  def severity(_), do: :warning
  def detail(e), do: "attempts=#{e.attempts}"
end

# --- Reserves context ---

defimpl Minted.Events.Display, for: Minted.Events.Reserves.ProofGenerated do
  def domain(_), do: "Reserves"
  def label(_), do: "Proof Generated"
  def severity(_), do: :info

  def detail(e) do
    ratio = if e.ratio == :infinity, do: "100%", else: "#{Float.round(e.ratio * 100, 1)}%"
    "ratio=#{ratio}, status=#{e.status}"
  end
end

defimpl Minted.Events.Display, for: Minted.Events.Reserves.ReserveDeficit do
  def domain(_), do: "Reserves"
  def label(_), do: "Reserve Deficit"
  def severity(_), do: :warning
  def detail(e), do: "deficit=#{e.deficit_sats} sats"
end

defimpl Minted.Events.Display, for: Minted.Events.Reserves.ReserveCriticalDeficit do
  def domain(_), do: "Reserves"
  def label(_), do: "Reserve Critical Deficit"
  def severity(_), do: :critical
  def detail(e), do: "deficit=#{e.deficit_sats} sats"
end

defimpl Minted.Events.Display, for: Minted.Events.Reserves.ReserveRecovered do
  def domain(_), do: "Reserves"
  def label(_), do: "Reserve Recovered"
  def severity(_), do: :info

  def detail(e) do
    ratio = if e.ratio == :infinity, do: "100%", else: "#{Float.round(e.ratio * 100, 1)}%"
    "ratio=#{ratio}"
  end
end

# --- Telemetry context ---

defimpl Minted.Events.Display, for: Minted.Events.Telemetry.AlertFired do
  def domain(e), do: e.domain
  def label(e), do: humanise(e.name)
  def severity(e), do: e.severity
  def detail(e), do: to_string(e.reason || "")

  defp humanise(value) do
    value
    |> to_string()
    |> String.replace("_", " ")
    |> String.split()
    |> Enum.map_join(" ", &String.capitalize/1)
  end
end

defimpl Minted.Events.Display, for: Minted.Events.Telemetry.AlertResolved do
  def domain(e), do: e.domain
  def label(e), do: humanise(e.name)
  def severity(_), do: :info
  def detail(_), do: "status=resolved"

  defp humanise(value) do
    value
    |> to_string()
    |> String.replace("_", " ")
    |> String.split()
    |> Enum.map_join(" ", &String.capitalize/1)
  end
end

defimpl Minted.Events.Display, for: Minted.Events.Telemetry.TorDown do
  def domain(_), do: "Tor"
  def label(_), do: "Tor Down"
  def severity(_), do: :critical
  def detail(%{reason: nil}), do: ""
  def detail(%{reason: reason}), do: "reason=#{reason}"
end

defimpl Minted.Events.Display, for: Minted.Events.Telemetry.TorDegraded do
  def domain(_), do: "Tor"
  def label(_), do: "Tor Degraded"
  def severity(_), do: :warning
  def detail(%{reason: nil}), do: ""
  def detail(%{reason: reason}), do: "reason=#{reason}"
end

defimpl Minted.Events.Display, for: Minted.Events.Telemetry.TorRecovered do
  def domain(_), do: "Tor"
  def label(_), do: "Tor Recovered"
  def severity(_), do: :info
  def detail(_), do: ""
end

defimpl Minted.Events.Display, for: Minted.Events.Telemetry.SystemStatusChanged do
  def domain(_), do: "System"
  def label(_), do: "System Status"

  def severity(e) do
    case e.status do
      :healthy -> :info
      :degraded -> :warning
      :critical -> :critical
      :halted -> :emergency
      _ -> :info
    end
  end

  def detail(e), do: "status=#{e.status}"
end

defimpl Minted.Events.Display, for: Minted.Events.Telemetry.KeysetRotated do
  def domain(_), do: "Mint"
  def label(_), do: "Keyset Rotated"
  def severity(_), do: :info
  def detail(e), do: "old=#{e.old_keyset_id} new=#{e.new_keyset_id}"
end

# --- Storage context ---

defimpl Minted.Events.Display, for: Minted.Events.Storage.LegacyKeyDecryptFallback do
  def domain(_), do: "Storage"
  def label(_), do: "Legacy Key Decrypt Fallback"
  def severity(_), do: :info
  def detail(e), do: "aad=#{e.aad}"
end
