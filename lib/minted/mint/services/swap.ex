defmodule Minted.Mint.Services.Swap do
  @moduledoc """
  Atomic token swap: exchange old tokens for new ones.

  Used for denomination changes, privacy refreshes, or splitting/combining tokens.
  Input amount must equal output amount. All-or-nothing atomicity.
  """

  require Logger

  alias Minted.Events.EventBus
  alias Minted.Events.Mint, as: MintEvents
  alias Minted.Mint.{Keyset, Token}
  alias Minted.Mint.Services.{Redemption, Signing}
  alias Minted.Mint.Signatures.Message
  alias Minted.Storage.Facade, as: StorageFacade
  alias Minted.Telemetry.Facade, as: TelemetryFacade

  @spec swap([Token.t()], [Message.t()], Keyset.t()) ::
          {:ok, [Minted.Mint.Signatures.Response.t()]} | {:error, term()}
  def swap(old_tokens, new_messages, %Keyset{} = keyset),
    do: swap(old_tokens, new_messages, keyset, keyset)

  @spec swap([Token.t()], [Message.t()], Keyset.t(), Keyset.t()) ::
          {:ok, [Minted.Mint.Signatures.Response.t()]} | {:error, term()}
  def swap([], _new_messages, _input_keyset, _output_keyset), do: {:error, :empty_swap}
  def swap(_old_tokens, [], _input_keyset, _output_keyset), do: {:error, :empty_swap}

  def swap(old_tokens, new_messages, %Keyset{} = input_keyset, %Keyset{} = output_keyset) do
    input_total = Enum.sum(Enum.map(old_tokens, & &1.amount))
    output_total = Enum.sum(Enum.map(new_messages, & &1.amount))

    if input_total != output_total do
      {:error, {:amount_mismatch, input_total, output_total}}
    else
      # Correlates swap_started ↔ swap_settled across a crash so
      # recovery blocks the right token hashes per interrupted swap —
      # without it every incomplete swap joined under the same key and
      # only the last one's hashes got blocked.
      swap_id = Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)

      # 1. WAL BEFORE reserve — crash recovery anchor. The `secret_hashes`
      #    field lets Recovery.queue_blocked_hashes/1 block the OLD
      #    tokens from being respent if the mint crashes after this WAL
      #    write but before commit_or_halt (which would have marked them
      #    spent). Contrast with `melt_started` which already carries
      #    the same field for the same reason.
      # 2. Reserve verifies signatures AND blocks re-use atomically.
      with :ok <-
             write_swap_wal(:swap_started, %{
               swap_id: swap_id,
               amount: input_total,
               input_count: length(old_tokens),
               output_count: length(new_messages),
               input_keyset_id: input_keyset.id,
               output_keyset_id: output_keyset.id,
               secret_hashes: Enum.map(old_tokens, &:crypto.hash(:sha256, &1.secret))
             }),
           # 2. Reserve old tokens (atomic verify + reversible hold).
           {:ok, _total} <- Redemption.verify_and_reserve(old_tokens, input_keyset) do
        # 4. Sign new tokens BEFORE committing the burn.
        finalise_swap(old_tokens, new_messages, input_keyset, output_keyset, input_total, swap_id)
      end
    end
  end

  # Commit MUST succeed before we hand signatures back to the client: the
  # pending table is not persisted across BEAM restart, so if we returned
  # new tokens while the old ones remained only in pending and a crash
  # followed before the next successful commit, the old tokens would no
  # longer be tracked as spent on recovery and could be respent alongside
  # the new ones.
  defp finalise_swap(old_tokens, new_messages, input_keyset, output_keyset, input_total, swap_id) do
    case Signing.sign(new_messages, output_keyset) do
      {:ok, signatures} ->
        with :ok <- commit_or_halt(old_tokens, input_keyset),
             :ok <- record_swap_success(old_tokens, output_keyset, input_total, swap_id) do
          {:ok, signatures}
        end

      {:error, _} = err ->
        Redemption.release_reservation(old_tokens, input_keyset)

        write_swap_wal(:swap_failed, %{
          swap_id: swap_id,
          amount: input_total,
          reason: :signing_failed,
          input_keyset_id: input_keyset.id
        })
        |> log_wal_failure(:swap_failed)

        err
    end
  end

  defp record_swap_success(old_tokens, output_keyset, input_total, swap_id) do
    with :ok <-
           write_swap_wal(:tokens_minted, %{
             amount: input_total,
             keyset_id: output_keyset.id,
             source: :swap
           }),
         :ok <-
           write_swap_wal(:swap_settled, %{
             swap_id: swap_id,
             amount: input_total,
             keyset_id: output_keyset.id
           }) do
      EventBus.publish(%MintEvents.TokensSwapped{
        amount: input_total,
        count: length(old_tokens),
        timestamp: DateTime.utc_now()
      })

      :ok
    else
      {:error, reason} ->
        Logger.error(
          "Swap: post-signing WAL write failed — tokens issued but audit trail incomplete. " <>
            "Halting mint to prevent unrecorded liability."
        )

        TelemetryFacade.set_halted("swap WAL write failure after signing")
        {:error, {:wal_write_failed, reason}}
    end
  end

  defp commit_or_halt(tokens, keyset) do
    case Redemption.commit_reservation(tokens, keyset) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error(
          "Swap: commit failed after signing: #{inspect(reason)}. " <>
            "Halting mint — a BEAM restart in this state would lose the " <>
            "pending reservation and allow the old tokens to be respent."
        )

        :telemetry.execute([:minted, :swap, :commit_failed_after_signing], %{count: 1}, %{})
        TelemetryFacade.set_halted("swap commit failure: #{inspect(reason)}")
        {:error, {:commit_failed, reason}}
    end
  end

  defp write_swap_wal(type, payload) do
    StorageFacade.write_wal(type, payload)
  rescue
    e ->
      Logger.error("Swap: WAL write failed for #{type}: #{inspect(e)}")
      {:error, :wal_write_failed}
  end

  defp log_wal_failure(:ok, _type), do: :ok

  defp log_wal_failure({:error, reason}, type) do
    Logger.error(
      "Swap: post-signing WAL write failed for #{type}: #{inspect(reason)}. " <>
        "Tokens issued but audit trail incomplete."
    )

    {:error, reason}
  end
end
