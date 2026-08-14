defmodule Minted.Wallet.Service do
  @moduledoc """
  Stateless orchestrator coordinating between Store, Signatures.Blind (NIF),
  Keysets.Store, Signing, Redemption, and Executor.

  Since the wallet IS the mint (self-custody), both Alice (client) and Bob (mint)
  roles execute server-side.
  """

  require Logger

  alias Minted.Events.EventBus
  alias Minted.Events.Mint, as: MintEvents
  alias Minted.Guards
  alias Minted.Lightning.Facade, as: LightningFacade
  alias Minted.Lightning.Payment
  alias Minted.Mint.Facade, as: MintFacade
  alias Minted.Mint.Quote
  alias Minted.Mint.Signatures.{Blind, Message}
  alias Minted.Mint.Token
  alias Minted.Storage.Facade, as: StorageFacade

  # --- Deposit — claim_deposit/1 ---

  @doc """
  Claims tokens for a paid deposit quote.

  Performs the full BDHKE roundtrip server-side:
  1. Generate secrets and blind them (Alice step 1)
  2. Claim the quote to prevent double-mint
  3. Sign blinded messages (Bob step 2)
  4. Unblind signatures (Alice step 3)
  5. Return tokens to caller (stored client-side in localStorage)
  """
  @spec claim_deposit(String.t()) :: {:ok, [Token.t()]} | {:error, term()}
  def claim_deposit(quote_id) do
    Guards.ensure_operational!()

    with {:ok, quote} <- MintFacade.get_quote(quote_id),
         :ok <- validate_paid_quote(quote),
         {:ok, keyset} <- get_keyset_for_quote(quote),
         {:ok, blind_pairs} <- generate_blinded_messages(quote.denomination_breakdown, keyset),
         # INVARIANT: WAL BEFORE claim — durability record must exist before
         # ETS state change. Crash after WAL but before claim = durable record exists.
         # Crash after claim but before WAL (old order) = record lost.
         :ok <- write_liability_wal(:tokens_minted, %{amount: quote.amount, quote_id: quote_id}),
         {:ok, _claimed} <- MintFacade.update_quote(quote_id, &Quote.claim/1),
         {:ok, signatures} <- sign_or_fail(blind_pairs, keyset, quote_id),
         {:ok, tokens} <- unblind_and_build_tokens(signatures, blind_pairs, keyset) do
      # Record fee collection in WAL + emit event.
      if quote.fee > 0 do
        write_liability_wal(:fees_collected, %{amount: quote.fee, quote_id: quote_id})

        EventBus.publish(%MintEvents.FeesCollected{
          amount: quote.fee,
          quote_id: quote_id,
          timestamp: DateTime.utc_now()
        })
      end

      Logger.info("Service: claim_deposit #{quote_id} minted #{quote.amount} sats (#{length(tokens)} tokens)")

      {:ok, tokens}
    else
      {:error, :wal_write_failed} = error ->
        # WAL failed before claim — no state to revert.
        Logger.warning("Service: claim_deposit #{quote_id} failed: WAL write failed")
        error

      {:error, reason} = error ->
        Logger.warning("Service: claim_deposit #{quote_id} failed: #{inspect(reason)}")
        error
    end
  end

  # --- Deposit — sign_blinded_messages/2 (Client-Side Blinding) ---

  @doc """
  Signs client-provided blinded messages for a paid deposit quote.

  The client has already performed Alice's step 1 (blinding) via WASM.
  This function validates the quote, checks denomination amounts match,
  claims the quote, and signs the blinded messages (Bob's step 2).

  Returns `{:ok, signatures}` where each signature contains `c_prime`,
  `keyset_id`, and DLEQ proof.
  """
  @spec sign_blinded_messages(String.t(), [map()]) :: {:ok, list()} | {:error, term()}
  def sign_blinded_messages(quote_id, client_messages) do
    Guards.ensure_operational!()

    with {:ok, quote} <- MintFacade.get_quote(quote_id),
         :ok <- validate_paid_quote(quote),
         {:ok, keyset} <- get_keyset_for_quote(quote),
         {:ok, blinded_msgs} <- parse_client_messages(client_messages),
         :ok <- check_no_duplicate_b_primes(blinded_msgs),
         :ok <- validate_amounts_match(blinded_msgs, quote.denomination_breakdown),
         # INVARIANT: WAL BEFORE claim — durability record must exist before
         # ETS state change. Crash after WAL but before claim = durable record exists.
         :ok <- write_liability_wal(:tokens_minted, %{amount: quote.amount, quote_id: quote_id}),
         {:ok, _claimed} <- MintFacade.update_quote(quote_id, &Quote.claim/1),
         {:ok, signatures} <- sign_or_fail_direct(blinded_msgs, keyset, quote_id) do
      # Record fee collection in WAL + emit event.
      if quote.fee > 0 do
        write_liability_wal(:fees_collected, %{amount: quote.fee, quote_id: quote_id})

        EventBus.publish(%MintEvents.FeesCollected{
          amount: quote.fee,
          quote_id: quote_id,
          timestamp: DateTime.utc_now()
        })
      end

      Logger.info(
        "Service: sign_blinded_messages #{quote_id} signed #{quote.amount} sats (#{length(signatures)} tokens)"
      )

      {:ok, signatures}
    else
      {:error, :wal_write_failed} = error ->
        # WAL failed before claim — no state to revert.
        Logger.warning("Service: sign_blinded_messages #{quote_id} failed: WAL write failed")
        error

      {:error, reason} = error ->
        Logger.warning("Service: sign_blinded_messages #{quote_id} failed: #{inspect(reason)}")
        error
    end
  end

  defp parse_client_messages(messages) when is_list(messages) do
    results =
      Enum.reduce_while(messages, {:ok, []}, fn msg, {:ok, acc} ->
        amount = Map.get(msg, "amount") || Map.get(msg, :amount)

        cond do
          not is_integer(amount) or amount <= 0 ->
            {:halt, {:error, :invalid_amount}}

          not Token.valid_denomination?(amount) ->
            {:halt, {:error, {:invalid_denomination, amount}}}

          true ->
            case decode_b_prime(msg) do
              {:ok, b_prime} ->
                {:cont, {:ok, [%Message{amount: amount, b_prime: b_prime} | acc]}}

              {:error, _} = err ->
                {:halt, err}
            end
        end
      end)

    case results do
      {:ok, msgs} -> {:ok, Enum.reverse(msgs)}
      error -> error
    end
  end

  defp decode_b_prime(msg) do
    hex = Map.get(msg, "b_prime") || Map.get(msg, :b_prime)

    case Base.decode16(hex || "", case: :mixed) do
      {:ok, bytes} when byte_size(bytes) == 33 -> {:ok, bytes}
      _ -> {:error, :invalid_blinded_message}
    end
  end

  defp validate_amounts_match(blinded_msgs, expected_amounts) do
    actual = Enum.map(blinded_msgs, & &1.amount) |> Enum.sort()
    expected = Enum.sort(expected_amounts)

    if actual == expected,
      do: :ok,
      else: {:error, :denomination_mismatch}
  end

  # --- Backup — export_backup/0 ---

  @doc """
  Exports the given tokens as a cashuA string.

  Returns `{:ok, cashu_string, token_count, total_amount}`.
  """
  @spec export_backup([Token.t()]) ::
          {:ok, String.t(), non_neg_integer(), non_neg_integer()} | {:error, term()}
  def export_backup(tokens) when is_list(tokens) do
    count = length(tokens)
    total = Enum.sum(Enum.map(tokens, & &1.amount))

    case MintFacade.serialize_token(tokens) do
      {:ok, cashu_string} -> {:ok, cashu_string, count, total}
      {:error, _} = error -> error
    end
  end

  # --- Restore — import_backup/1 ---

  @doc """
  Imports tokens from a cashuA string.

  Deserializes, verifies signatures, and filters out already-spent tokens.
  Returns `{:ok, verified_tokens, skipped_count, amount_added}` — caller
  is responsible for storing tokens client-side.
  """
  @spec import_backup(String.t()) ::
          {:ok, [Token.t()], non_neg_integer(), non_neg_integer()} | {:error, term()}
  def import_backup(cashu_string) do
    with {:ok, tokens} <- MintFacade.deserialize_token(cashu_string) do
      {live, skipped} =
        Enum.split_with(tokens, fn t ->
          not MintFacade.spent?(t.secret)
        end)

      with {:ok, grouped} <- resolve_token_keysets(live),
           {:ok, verifiable, expired_count} <- partition_expired_groups(grouped),
           :ok <- verify_grouped_signatures(verifiable) do
        accepted = Enum.flat_map(verifiable, fn {_keyset, group_tokens} -> group_tokens end)
        amount_added = Enum.sum(Enum.map(accepted, & &1.amount))
        {:ok, accepted, length(skipped) + expired_count, amount_added}
      end
    end
  end

  # Tokens under an EXPIRED keyset are unspendable — the private keys
  # are destroyed, so the mint can no longer verify them. Skip them
  # instead of feeding :destroyed sentinels into the NIF verifier.
  defp partition_expired_groups(grouped) do
    {expired, verifiable} =
      Enum.split_with(grouped, fn {keyset, _tokens} -> keyset.status == :expired end)

    expired_count = expired |> Enum.flat_map(fn {_keyset, ts} -> ts end) |> length()
    {:ok, verifiable, expired_count}
  end

  # --- Withdrawal — melt_tokens/2 ---

  @doc """
  Melts tokens to pay a Lightning invoice.

  Tokens are provided by the caller (selected client-side from localStorage).

  1. Groups tokens by keyset_id, resolves each keyset
  2. Reserves tokens in spent set (blocks re-use)
  3. Executes Lightning payment
  4. On success: commits reservation
  5. On failure: releases reservation, tokens stay in client wallet
  """
  # Same cap the /v1/melt controller enforces. Bounds serial hashing
  # through the single Spent GenServer; a crafted LiveView client
  # could otherwise flood the mailbox with a huge token batch and
  # DoS every concurrent melt/swap sharing the same GenServer.
  @max_melt_input_tokens 1000

  @spec melt_tokens(String.t(), non_neg_integer(), [Token.t()]) :: {:ok, map()} | {:error, term()}
  def melt_tokens(_bolt11, _client_fee, tokens)
      when is_list(tokens) and length(tokens) > @max_melt_input_tokens do
    {:error, :batch_too_large}
  end

  def melt_tokens(bolt11, _client_fee, tokens)
      when is_binary(bolt11) and is_list(tokens) do
    with {:ok, amount} <- parse_bolt11_amount(bolt11),
         fee = melt_fee(amount),
         token_total = Enum.sum(Enum.map(tokens, & &1.amount)),
         required = amount + fee,
         true <- token_total >= required || {:error, :insufficient_tokens},
         overpayment = token_total - required,
         {:ok, grouped} <- resolve_token_keysets(tokens),
         {:ok, quote} <- MintFacade.create_melt_quote(amount, bolt11),
         # Transition to :paying BEFORE reserving — the quote is the
         # SettlementResolver's handle on this melt if the payment
         # outcome turns ambiguous.
         {:ok, _paying} <- MintFacade.update_quote(quote.id, &Quote.start_payment/1),
         :ok <- reserve_or_abort(grouped, quote.id) do
      execute_melt_payment(%{
        bolt11: bolt11,
        amount: amount,
        fee: fee,
        overpayment: overpayment,
        selected: tokens,
        grouped: grouped,
        quote: quote
      })
    end
  end

  # Reserve all keyset groups; on failure the reservations are already
  # rolled back — abort the quote too, so the bolt11 is not wedged in
  # :paying behind a melt the client will never complete.
  defp reserve_or_abort(grouped, quote_id) do
    case verify_and_reserve_grouped(grouped) do
      :ok ->
        :ok

      {:error, _} = err ->
        MintFacade.update_quote(quote_id, &Quote.abort_payment/1)
        err
    end
  end

  # Same duplicate-B' rejection the /v1/mint claim path enforces
  # (mint_controller.ex:check_no_duplicate_b_primes). Two blinded
  # messages with identical B' get identical C' signatures, so the
  # client ends up with two Tokens whose C's collide — spending
  # one silently burns the other. Self-inflicted only (the wallet
  # generates its own blinded messages), but the check exists at
  # every other signing boundary and belongs here for symmetry.
  defp check_no_duplicate_b_primes(blinded_msgs) do
    b_primes = Enum.map(blinded_msgs, & &1.b_prime)

    if MapSet.size(MapSet.new(b_primes)) == length(b_primes) do
      :ok
    else
      {:error, :duplicate_blinded_messages}
    end
  end

  defp resolve_token_keysets(tokens) do
    tokens
    |> Enum.group_by(& &1.keyset_id)
    |> Enum.reduce_while({:ok, []}, fn {kid, group}, {:ok, acc} ->
      case lookup_keyset(kid) do
        {:ok, keyset} -> {:cont, {:ok, [{keyset, group} | acc]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp lookup_keyset(keyset_id) do
    case StorageFacade.get_keyset(keyset_id) do
      {:ok, store_map} -> MintFacade.keyset_from_store_map(store_map)
      :not_found -> {:error, {:keyset_not_found, keyset_id}}
    end
  end

  defp verify_and_reserve_grouped(grouped) do
    # Reserve groups sequentially, but ROLL BACK every reservation
    # we already made on the first failure. The previous impl left
    # groups 1..N-1 reserved when group N failed, so nothing swept
    # them and `promote_pending_to_main` on the next restart marked
    # them permanently spent — the mint paid nothing yet the user's
    # tokens were gone. Track reserved groups as we go and release
    # them if any subsequent group fails.
    Enum.reduce_while(grouped, {:ok, []}, fn {keyset, tokens}, {:ok, reserved} ->
      case MintFacade.verify_and_reserve(tokens, keyset) do
        {:ok, _total} ->
          {:cont, {:ok, [{keyset, tokens} | reserved]}}

        err ->
          # Redemption.verify_and_reserve returns both 2-tuple and
          # 3-tuple errors (`{:error, :invalid_signature, index}`);
          # roll back on either shape.
          release_all(reserved)
          {:halt, err}
      end
    end)
    |> case do
      {:ok, _reserved} -> :ok
      err -> err
    end
  end

  defp release_all(reserved) do
    Enum.each(reserved, fn {keyset, tokens} ->
      MintFacade.release_reservation(tokens, keyset)
    end)
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  if Mix.env() == :test do
    @doc """
    Test-only accessor for the multi-keyset reservation walker.
    Lets scenario tests exercise the rollback path (release all
    previously-reserved groups when a later group fails) without a
    full melt round trip.
    """
    def __verify_and_reserve_grouped__(grouped), do: verify_and_reserve_grouped(grouped)
  end

  # The melt-tracking id is a synthetic surrogate for the API's
  # quote_id — the wallet path has no /v1/melt/quote step, so we
  # generate one here purely so recovery can join `:melt_started` to
  # `:melt_settled` and route blocked hashes correctly.
  defp generate_melt_id, do: :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)

  # Retries mirror the API path's `commit_with_retry/3`. Copied here
  # rather than shared because the module boundary between wallet +
  # controller is deliberate; a shared helper would drag one into
  # the other's dependency graph.
  @commit_retries 3
  @commit_retry_delay_ms 100

  defp commit_with_retry(_grouped, retries_left) when retries_left <= 0,
    do: {:error, :commit_exhausted}

  defp commit_with_retry(grouped, retries_left) do
    result =
      Enum.reduce_while(grouped, :ok, fn {keyset, tokens}, :ok ->
        case MintFacade.commit_reservation(tokens, keyset) do
          :ok -> {:cont, :ok}
          {:error, _} = err -> {:halt, err}
        end
      end)

    case result do
      :ok ->
        :ok

      {:error, _} ->
        Process.sleep(@commit_retry_delay_ms)
        commit_with_retry(grouped, retries_left - 1)
    end
  end

  defp execute_melt_payment(%{
         bolt11: bolt11,
         amount: amount,
         fee: fee,
         overpayment: overpayment,
         selected: selected,
         grouped: grouped,
         quote: quote
       }) do
    melt_id = generate_melt_id()
    # Fee cap forwarded to phoenixd: mint never subsidizes routing
    # beyond the reserve the wallet already showed the user.
    payment = Payment.new(bolt11: bolt11, amount_sats: amount, fee_limit_sats: fee)
    secret_hashes = Enum.map(selected, fn t -> :crypto.hash(:sha256, t.secret) end)
    keyset_ids = Enum.map(grouped, fn {keyset, _tokens} -> keyset.id end)

    ln_payment_hash =
      case LightningFacade.parse_bolt11_payment_hash(bolt11) do
        {:ok, hash} -> hash
        _ -> nil
      end

    # WAL BEFORE payment — carries the same payload the API melt does
    # (secret_hashes, keyset ids, melt-id, payment id, quote id, bolt11,
    # amount) so a VM crash post-payment can rebuild the blocked-hash
    # set and prevent double-spend of tokens the mint has already paid
    # Lightning sats for.
    case write_liability_wal(:melt_started, %{
           melt_id: melt_id,
           payment_id: payment.id,
           quote_id: quote.id,
           ln_payment_hash: ln_payment_hash,
           bolt11: bolt11,
           amount: amount,
           token_count: length(selected),
           secret_hashes: secret_hashes,
           keyset_ids: keyset_ids
         }) do
      {:error, _} ->
        release_grouped(grouped)
        MintFacade.update_quote(quote.id, &Quote.abort_payment/1)
        {:error, :wal_write_failed}

      _ ->
        # Resolution context for the SettlementResolver, mirroring the
        # API melt path. Wallet melts can span multiple keysets, so the
        # context carries per-keyset token groups.
        melt_context = %{
          payment_id: payment.id,
          ln_payment_hash: ln_payment_hash,
          groups: Enum.map(grouped, fn {keyset, tokens} -> {keyset.id, tokens} end)
        }

        MintFacade.update_quote(quote.id, fn q -> {:ok, %{q | melt_context: melt_context}} end)

        do_execute_melt(%{
          amount: amount,
          fee: fee,
          overpayment: overpayment,
          selected: selected,
          grouped: grouped,
          melt_id: melt_id,
          payment: payment,
          quote: quote
        })
    end
  end

  defp do_execute_melt(%{
         amount: amount,
         fee: fee,
         overpayment: overpayment,
         selected: selected,
         grouped: grouped,
         melt_id: melt_id,
         payment: payment,
         quote: quote
       }) do
    case LightningFacade.execute_payment_and_await(payment) do
      {:ok, result} ->
        # Deduct actual routing fee from change. The fee estimate was
        # collected upfront to reserve enough tokens. The actual routing
        # fee may be less — the difference goes back as extra change.
        actual_routing_fee = Map.get(result, :routing_fee, 0) || 0
        change_after_routing = max(0, overpayment + fee - actual_routing_fee)

        maybe_alert_absorbed_fee(melt_id, fee, actual_routing_fee)

        Logger.info(
          "Service: melt settled, melt_id=#{melt_id}, " <>
            "routing_fee=#{actual_routing_fee}, estimated_fee=#{fee}, " <>
            "change=#{change_after_routing}"
        )

        # Sign change tokens BEFORE commit — the user must get their change
        # regardless of whether commit succeeds. If commit fails, tokens stay
        # in the pending table (fail-safe: no resurrection) but the user
        # still gets their overpayment back.
        change_tokens = sign_melt_change(change_after_routing, grouped)

        case commit_with_retry(grouped, @commit_retries) do
          :ok ->
            write_liability_wal(:melt_settled, %{
              melt_id: melt_id,
              payment_id: payment.id,
              quote_id: quote.id,
              preimage: Map.get(result, :preimage)
            })

            settle_quote_paid(quote.id)

            {:ok,
             %{
               amount: amount,
               tokens_spent: length(selected),
               change: change_tokens,
               routing_fee: actual_routing_fee,
               status: :paid
             }}

          {:error, reason} ->
            # Commit exhausted AFTER the Lightning payment settled.
            # Tokens live only in the volatile pending table and would
            # vanish on the next restart — write the commit_failed
            # anchor so recovery re-blocks their hashes on next boot,
            # and park the quote so the SettlementResolver can finish
            # the commit.
            write_liability_wal(:melt_settled, %{
              melt_id: melt_id,
              payment_id: payment.id,
              quote_id: quote.id,
              preimage: Map.get(result, :preimage),
              commit_failed: true
            })

            Logger.error(
              "Service: wallet melt commit failed after payment settled, tokens held in pending, " <>
                "melt_id=#{melt_id}, reason=#{inspect(reason)}"
            )

            MintFacade.update_quote(quote.id, &Quote.mark_settlement_unknown/1)

            {:ok,
             %{
               amount: amount,
               tokens_spent: length(selected),
               change: change_tokens,
               routing_fee: actual_routing_fee,
               status: :paid
             }}
        end

      {:error, :settlement_timeout} ->
        # Outer soft-timeout — outcome unknown. Keep tokens reserved
        # and park the quote for the SettlementResolver.
        Logger.error("Service: melt settlement timeout, tokens remain reserved")
        MintFacade.update_quote(quote.id, &Quote.mark_settlement_unknown/1)
        {:error, :settlement_unknown}

      {:error, {:settlement_unknown, reason}} ->
        # Ambiguous outcome from the executor (HTTP timeout, transport,
        # task crash, 5xx). Tokens MUST stay reserved — the payment
        # may still settle on Lightning.
        Logger.error("Service: melt outcome unknown, reason=#{inspect(reason)} — tokens remain reserved")
        MintFacade.update_quote(quote.id, &Quote.mark_settlement_unknown/1)
        {:error, :settlement_unknown}

      {:error, {:payment_exhausted, _reason} = reason} ->
        # Retry-ladder exhausted with retryable errors — every attempt
        # was a known "did not happen on Lightning", so release is safe.
        release_grouped(grouped)
        MintFacade.update_quote(quote.id, &Quote.abort_payment/1)
        {:error, {:payment_failed, reason}}

      {:error, reason} ->
        # Any other terminal error — release is safe.
        release_grouped(grouped)
        MintFacade.update_quote(quote.id, &Quote.abort_payment/1)
        {:error, {:payment_failed, reason}}
    end
  end

  # Settle the melt quote :paying → :paid → :claimed. Log rather than
  # crash on a transition hiccup — the money side (commit + WAL) is
  # already durable at this point.
  defp settle_quote_paid(quote_id) do
    with {:ok, _} <- MintFacade.update_quote(quote_id, &Quote.mark_paid/1),
         {:ok, _} <- MintFacade.update_quote(quote_id, &Quote.claim/1) do
      :ok
    else
      {:error, reason} ->
        Logger.warning("Service: melt quote settle transition failed, quote_id=#{quote_id}, reason=#{inspect(reason)}")

        :ok
    end
  end

  defp release_grouped(grouped) do
    Enum.each(grouped, fn {keyset, tokens} ->
      MintFacade.release_reservation(tokens, keyset)
    end)
  end

  # --- Melt change ---
  #
  # When the user's tokens exceed the Lightning payment + fee, the
  # overpayment is returned as new signed tokens. We generate blinded
  # messages server-side (same as the mint flow), sign them, unblind,
  # and return the resulting tokens to the wallet.

  defp sign_melt_change(0, _grouped), do: []

  defp sign_melt_change(overpayment, _grouped) when overpayment > 0 do
    # Sign change tokens with the currently ACTIVE keyset — never with
    # an input keyset (which may be retired or expired). The API melt
    # path resolves the active keyset for this reason; the wallet path
    # was picking `hd(grouped)` (the caller's oldest input keyset),
    # which meant any melt whose inputs were on a rotated keyset would
    # fail to sign change and silently absorb the overpayment.
    case active_keyset_for_change() do
      {:ok, keyset} ->
        change_amounts = Token.decompose_amount(overpayment)

        # WAL before signing: record the liability BEFORE we produce
        # signed tokens. If we crash after signing but before the
        # client receives the tokens, the WAL ensures we know the
        # liability exists.
        case write_liability_wal(:tokens_minted, %{
               amount: overpayment,
               keyset_id: keyset.id,
               source: :melt_change
             }) do
          {:error, reason} ->
            Logger.error("Service: melt change WAL write failed, overpayment absorbed, reason=#{inspect(reason)}")

            []

          _ ->
            do_sign_melt_change(overpayment, change_amounts, keyset)
        end

      {:error, reason} ->
        Logger.error(
          "Service: no active keyset to sign melt change, overpayment absorbed, " <>
            "reason=#{inspect(reason)}"
        )

        []
    end
  end

  defp active_keyset_for_change do
    case MintFacade.active_keyset_id() do
      nil -> {:error, :no_active_keyset}
      keyset_id -> lookup_keyset(keyset_id)
    end
  end

  defp do_sign_melt_change(overpayment, change_amounts, keyset) do
    case generate_blinded_messages(change_amounts, keyset) do
      {:ok, blind_pairs} ->
        wire_msgs = build_wire_blinded_messages(blind_pairs)

        case MintFacade.sign(wire_msgs, keyset, publish_event: false) do
          {:ok, signatures} ->
            case unblind_and_build_tokens(signatures, blind_pairs, keyset) do
              {:ok, tokens} ->
                EventBus.publish(%MintEvents.TokensMinted{
                  amount: overpayment,
                  count: length(tokens),
                  timestamp: DateTime.utc_now()
                })

                Logger.info("Service: melt change returned #{overpayment} sats as #{length(tokens)} token(s)")
                tokens

              {:error, reason} ->
                Logger.error("Service: melt change unblinding failed: #{inspect(reason)}, overpayment absorbed")
                []
            end

          {:error, reason} ->
            Logger.error("Service: melt change signing failed: #{inspect(reason)}, overpayment absorbed")
            []
        end

      {:error, reason} ->
        Logger.error("Service: melt change blinding failed: #{inspect(reason)}, overpayment absorbed")
        []
    end
  end

  # --- Private — BDHKE helpers ---

  defp generate_blinded_messages(amounts, keyset) when is_list(amounts) do
    results =
      Enum.reduce_while(amounts, {:ok, []}, fn amount, {:ok, acc} ->
        secret = :crypto.strong_rand_bytes(32)

        case MintFacade.blind(secret) do
          {:ok, blinded_msg} ->
            {:cont, {:ok, [{amount, blinded_msg, MintFacade.get_keyset_key(keyset, amount)} | acc]}}

          {:error, reason} ->
            {:halt, {:error, {:blind_failed, reason}}}
        end
      end)

    case results do
      {:ok, pairs} -> {:ok, Enum.reverse(pairs)}
      error -> error
    end
  end

  defp build_wire_blinded_messages(blind_pairs) do
    Enum.map(blind_pairs, fn {amount, blinded_msg, _key_result} ->
      %Message{amount: amount, b_prime: blinded_msg.b_prime}
    end)
  end

  # Signs Message structs directly (client-provided B' values).
  # On failure, the quote remains claimed — NEVER revert to :paid.
  # The stale_claimed recovery mechanism will finalize it.
  defp sign_or_fail_direct(blinded_msgs, keyset, quote_id) do
    case MintFacade.sign(blinded_msgs, keyset) do
      {:ok, _signatures} = ok ->
        ok

      {:error, _} = error ->
        Logger.error("Service: signing failed for quote #{quote_id}, quote remains claimed")
        error
    end
  end

  # Signs blind_pairs from generate_blinded_messages (server-side blinding).
  # On failure, the quote remains claimed — NEVER revert to :paid.
  defp sign_or_fail(blind_pairs, keyset, quote_id) do
    wire_msgs = build_wire_blinded_messages(blind_pairs)

    case MintFacade.sign(wire_msgs, keyset) do
      {:ok, _signatures} = ok ->
        ok

      {:error, _} = error ->
        Logger.error("Service: signing failed for quote #{quote_id}, quote remains claimed")
        error
    end
  end

  defp unblind_and_build_tokens(signatures, blind_pairs, keyset) do
    if length(signatures) != length(blind_pairs) do
      Logger.error(
        "Service: signature count mismatch — " <>
          "got #{length(signatures)}, expected #{length(blind_pairs)}"
      )

      {:error, :signature_count_mismatch}
    else
      do_unblind_tokens(signatures, blind_pairs, keyset)
    end
  end

  defp do_unblind_tokens(signatures, blind_pairs, keyset) do
    pairs = Enum.zip(signatures, blind_pairs)

    results =
      Enum.reduce_while(pairs, {:ok, []}, fn {sig, blind_pair}, {:ok, acc} ->
        case unblind_single(sig, blind_pair, keyset) do
          {:ok, token} -> {:cont, {:ok, [token | acc]}}
          {:error, _} = error -> {:halt, error}
        end
      end)

    case results do
      {:ok, tokens} -> {:ok, Enum.reverse(tokens)}
      error -> error
    end
  end

  defp unblind_single(sig, {amount, blinded_msg, key_result}, keyset) do
    with {:ok, {privkey, pubkey}} <- key_result,
         blind_sig = %Blind.BlindSignature{c_prime: sig.c_prime},
         {:ok, proof} <- MintFacade.unblind(blind_sig, blinded_msg, pubkey),
         :ok <- Cashew.verify(privkey, proof.secret, proof.c) do
      {:ok, %Token{amount: amount, secret: proof.secret, c: proof.c, keyset_id: keyset.id}}
    else
      {:error, :invalid_signature} ->
        # Unblinding produced a C that does not verify under the mint's key
        # for this secret. Under 1-of-1 signing this is effectively impossible
        # (the mint just computed the signature itself), but under FROST a
        # bad partial aggregation or a peer contributing a bogus share
        # would land here and an unverified token would otherwise be handed
        # to the user to discover as unspendable later.
        Logger.error("Service: unblinded proof failed verification for keyset #{keyset.id}")
        {:error, :proof_verification_failed}

      {:error, reason} when is_atom(reason) ->
        {:error, {:key_lookup_failed, reason}}

      {:error, reason} ->
        {:error, {:unblind_failed, reason}}
    end
  end

  # --- Private — validation helpers ---

  defp validate_paid_quote(%Quote{status: :paid, type: :mint, payment_hash: hash} = quote)
       when is_binary(hash) do
    if Quote.expired?(quote),
      do: {:error, :quote_expired},
      else: :ok
  end

  defp validate_paid_quote(%Quote{status: :paid, payment_hash: nil}),
    do: {:error, :payment_not_verified}

  defp validate_paid_quote(%Quote{status: :paid, type: type}) when type != :mint,
    do: {:error, {:wrong_quote_type, type}}

  defp validate_paid_quote(%Quote{status: status}), do: {:error, {:quote_not_paid, status}}

  # Resolves the keyset the quote committed to at creation. Uses the
  # pinned `quote.keyset_id`, never re-reads "whatever is active now" —
  # that drift is the DLEQ-mismatch bug this pinning solves. Accepts
  # `:active` and `:retired` keysets (both have live private keys);
  # `:expired` keysets have their private keys destroyed and cannot sign.
  defp get_keyset_for_quote(%Quote{keyset_id: nil}), do: {:error, :quote_missing_keyset}

  defp get_keyset_for_quote(%Quote{keyset_id: keyset_id}) do
    with {:ok, store_map} <- StorageFacade.get_keyset(keyset_id),
         {:ok, keyset} <- MintFacade.keyset_from_store_map(store_map) do
      if keyset.status in [:active, :retired] do
        {:ok, keyset}
      else
        {:error, {:keyset_unavailable, keyset.status}}
      end
    else
      :not_found -> {:error, {:keyset_not_found, keyset_id}}
      {:error, _} = err -> err
    end
  end

  defp verify_grouped_signatures(grouped) do
    Enum.reduce_while(grouped, :ok, fn {keyset, tokens}, :ok ->
      case verify_signatures(tokens, keyset) do
        :ok -> {:cont, :ok}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp verify_signatures([], _keyset), do: :ok

  defp verify_signatures(tokens, keyset) do
    Enum.reduce_while(tokens, :ok, fn token, :ok ->
      case verify_token_signature(token, keyset) do
        :ok -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp verify_token_signature(%Token{amount: amount, secret: secret, c: c}, keyset) do
    case MintFacade.get_keyset_key(keyset, amount) do
      {:ok, {privkey, _pubkey}} ->
        Cashew.verify(privkey, secret, c)

      {:error, :denomination_not_found} ->
        {:error, {:denomination_not_found, amount}}
    end
  end

  # Server-authoritative melt fee from the configured withdrawal PPM rate.
  # Never trust the client-provided fee.
  defp melt_fee(amount) when is_integer(amount) and amount > 0 do
    MintFacade.withdrawal_fee(amount)
  end

  defp parse_bolt11_amount(bolt11) do
    case FireBird.Bolt11.parse_amount(bolt11) do
      {:ok, amount} when amount > 0 -> {:ok, amount}
      {:ok, _} -> {:error, :invalid_amount}
      {:error, reason} -> {:error, {:bolt11_parse_error, reason}}
    end
  end

  defp write_liability_wal(type, payload) do
    StorageFacade.write_wal(type, payload)
  rescue
    e ->
      Logger.error("Service: WAL write failed for #{type}: #{inspect(e)}")
      :telemetry.execute([:minted, :wal, :write_failure], %{count: 1}, %{type: type})
      {:error, :wal_write_failed}
  end

  # Symmetric with the API controller's absorbed-fee alert. With
  # phoenixd's `maxFeeFlatSat` enforced end-to-end this SHOULDN'T
  # fire — a fired alert means the cap didn't reach the node.
  defp maybe_alert_absorbed_fee(_melt_id, reserve, actual) when actual <= reserve, do: :ok

  defp maybe_alert_absorbed_fee(melt_id, reserve, actual) do
    absorbed = actual - reserve

    Logger.error(
      "Service: routing fee exceeded reserve, melt_id=#{melt_id}, " <>
        "reserve=#{reserve}, actual=#{actual}, absorbed=#{absorbed}"
    )

    :telemetry.execute(
      [:minted, :melt, :fee_absorbed],
      %{absorbed_sats: absorbed, reserve_sats: reserve, actual_sats: actual},
      %{melt_id: melt_id}
    )
  end
end
