defmodule Minted.Reserves.Facade do
  @moduledoc false

  alias Minted.Reserves.Publishers.Nostr
  alias Minted.Reserves.Trackers.{Fees, Liability}

  @doc """
  Returns the current solvency snapshot for UI display.

  Grey (no data) until the first proof is generated. After that,
  returns the ratio, held, outstanding, and delta. Both the admin
  dashboard and the wallet UI call this same function.
  """
  @spec solvency() :: map()
  def solvency do
    proof = latest_proof()
    liability = Liability.current()

    # Pass the SIGNED outstanding through — burned > minted is an
    # invariant violation, not a large positive liability. The
    # previous abs() surfaced a negative outstanding as if the mint
    # were 100%+ backing user tokens, masking a bookkeeping bug that
    # halts on `:liability_invariant` at the tracker level.
    outstanding = liability.outstanding

    case proof do
      %{snapshot: %{total_held: held}} when is_integer(held) ->
        {status, pct, title} = solvency_status(held, outstanding)

        %{
          status: status,
          pct: pct,
          held: held,
          outstanding: outstanding,
          delta: held - outstanding,
          title: title
        }

      _ ->
        %{
          status: :pending,
          pct: 0,
          held: 0,
          outstanding: 0,
          delta: 0,
          title: "Solvency: awaiting first proof"
        }
    end
  rescue
    _ ->
      %{status: :pending, pct: 0, held: 0, outstanding: 0, delta: 0, title: "Solvency: unavailable"}
  end

  # Negative outstanding = burned > minted = accounting corruption.
  # Surface it as its own status so the UI can render it distinctly
  # from a normal solvency ratio; separate halts on
  # `:liability_invariant` still fire at the tracker level.
  defp solvency_status(_held, outstanding) when outstanding < 0 do
    {:invariant_violation, 0, "Solvency: burned > minted — INVARIANT VIOLATION"}
  end

  defp solvency_status(_held, 0), do: {:active, 999, "Solvency: 999%"}

  defp solvency_status(held, outstanding) when outstanding > 0 do
    pct = min(round(held / outstanding * 100), 999)
    {:active, pct, "Solvency: #{pct}%"}
  end

  @doc "Returns the latest reserve proof."
  @spec latest_proof() :: Vault.Proof.t() | nil
  def latest_proof do
    Vault.Generator.latest()
  end

  @doc "Returns a reverse-chronological list of recent reserve proofs, up to the given limit."
  @spec proof_history(pos_integer()) :: [Vault.Proof.t()]
  def proof_history(limit) when is_integer(limit) and limit > 0 do
    Vault.Generator.history(limit)
  end

  @doc "Resets mint/burn liability counters."
  @spec reset_counters() :: :ok
  def reset_counters do
    Liability.reset_counters()
  end

  @doc "Restores a liability counter from recovery."
  @spec restore_counters(:minted | :burned, non_neg_integer()) :: :ok
  def restore_counters(type, amount) do
    Liability.restore_counters(type, amount)
  end

  @doc "Returns the total minted amount in sats."
  @spec minted_total() :: non_neg_integer()
  def minted_total do
    Liability.minted_total()
  end

  @doc "Returns the total burned amount in sats."
  @spec burned_total() :: non_neg_integer()
  def burned_total do
    Liability.burned_total()
  end

  @doc """
  Returns the current liability snapshot: minted, burned, and outstanding
  totals. Used by the admin dashboard to render solvency status.
  """
  @spec liability_snapshot() :: %{minted: non_neg_integer(), burned: non_neg_integer(), outstanding: integer()}
  def liability_snapshot, do: Liability.current()

  @doc "Returns aggregated fee totals."
  @spec fee_totals() :: %{total_collected: non_neg_integer(), event_count: non_neg_integer()}
  def fee_totals, do: Fees.current()

  @doc """
  Returns fee totals for the last 24 hours: total sats collected,
  event count, and average per event. Used by the admin dashboard.
  """
  @spec fees_last_24h() :: %{total: non_neg_integer(), count: non_neg_integer(), avg: non_neg_integer()}
  def fees_last_24h, do: Fees.last_24h()

  @doc """
  Returns the hex-encoded Nostr signing pubkey (BIP-340 x-only,
  secp256k1) — the key that signs each NIP-33 event so relays/clients
  can verify event authenticity. Returns `{:error, :not_available}`
  if the publisher hasn't loaded its key yet.
  """
  @spec nostr_pubkey() :: {:ok, String.t()} | {:error, :not_available}
  def nostr_pubkey, do: Nostr.pubkey()

  @doc """
  Returns the hex-encoded Ed25519 guardian pubkey of the issuing
  node — the key that signs each proof's `threshold_signature` field
  over `Vault.Proof.canonical_bytes/1`. Different curve and different
  key from the Nostr publishing pubkey; the two surfaces serve
  different verification paths and should never be confused.
  """
  @spec guardian_pubkey() :: {:ok, String.t()} | {:error, :not_available}
  def guardian_pubkey do
    case Vault.Generator.guardian_pubkey() do
      {:ok, pub} when is_binary(pub) -> {:ok, Base.encode16(pub, case: :lower)}
      {:error, reason} -> {:error, reason}
    end
  rescue
    _ -> {:error, :not_available}
  end

  @doc "Resets fee tracking counters."
  @spec reset_fee_counters() :: :ok
  def reset_fee_counters, do: Fees.reset_counters()

  @doc "Restores a fee counter from recovery."
  @spec restore_fee_counter(non_neg_integer()) :: :ok
  def restore_fee_counter(amount), do: Fees.restore_counters(amount)
end
