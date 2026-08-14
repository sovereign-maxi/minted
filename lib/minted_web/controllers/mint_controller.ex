defmodule MintedWeb.MintController do
  @moduledoc """
  Handles deposit (mint), withdrawal (melt), swap, and spend check endpoints.

  Cashu NUT-03 (swap), NUT-04 (mint), NUT-05 (melt), NUT-07 (check).
  """

  use MintedWeb, :controller

  require Logger

  alias Minted.Events.EventBus
  alias Minted.Events.Mint, as: MintEvents
  alias Minted.Lightning.Facade, as: LightningFacade
  alias Minted.Lightning.Payment
  alias Minted.Mint.Facade
  alias Minted.Mint.{Keyset, Quote, Token}
  alias Minted.Mint.Signatures.Message
  alias Minted.Storage.Facade, as: StorageFacade
  alias MintedWeb.JSON

  action_fallback MintedWeb.FallbackController

  plug :ensure_operational when action in [:create_quote, :claim_quote, :melt_quote, :melt, :swap]

  @commit_retries 3
  @commit_retry_delay_ms 100

  # --- NUT-04: Mint (Deposit) ---

  @doc """
  POST /v1/mint/quote
  Creates a mint quote for depositing sats into eCash.
  """
  def create_quote(conn, %{"amount" => amount, "unit" => "sat"})
      when is_integer(amount) and amount > 0 do
    with {:ok, quote} <- Facade.create_mint_quote(amount),
         {:ok, invoice} <-
           LightningFacade.create_invoice(amount + quote.fee, "cashu mint",
             quote_id: quote.id,
             # Pin invoice expiry to remaining quote TTL so phoenixd
             # can't accept a payment for an expired quote.
             expiry_seconds: DateTime.diff(quote.expires_at, DateTime.utc_now())
           ),
         {:ok, quote} <-
           Facade.update_quote(quote.id, &Quote.attach_invoice(&1, invoice.bolt11)) do
      conn
      |> put_status(200)
      |> json(%{
        quote: quote.id,
        request: quote.invoice,
        state: format_quote_state(quote.status),
        expiry: DateTime.to_unix(quote.expires_at)
      })
    end
  end

  def create_quote(_conn, _params) do
    {:error, :invalid_request}
  end

  @doc """
  POST /v1/mint/quote/:id
  Claims signed blinded messages after Lightning invoice is paid.
  """
  def claim_quote(conn, %{"id" => id} = params) do
    case Facade.get_quote(id) do
      {:ok, quote} ->
        handle_quote_claim(conn, quote, id, params)

      {:error, :not_found} ->
        {:error, :quote_not_found}
    end
  end

  defp handle_quote_claim(conn, quote, id, params) do
    case quote.status do
      :expired ->
        {:error, :quote_expired}

      :paid ->
        # Late claim of an already-paid quote is allowed — the
        # payment is a terminal positive that TTL cannot revoke.
        # See `Minted.Mint.Quote.claim/1`.
        if quote.payment_hash do
          claim_paid_quote(conn, quote, params)
        else
          {:error, :payment_not_verified}
        end

      :claimed ->
        {:error, :invalid_transition}

      _other ->
        conn
        |> put_status(200)
        |> json(%{quote: id, state: format_quote_state(quote.status), signatures: []})
    end
  end

  defp claim_paid_quote(conn, quote, params) do
    outputs = Map.get(params, "outputs", [])

    if not is_list(outputs) or length(outputs) > 1000 or outputs == [] do
      {:error, :invalid_request}
    else
      claim_paid_quote_inner(conn, quote, outputs)
    end
  end

  defp claim_paid_quote_inner(conn, quote, outputs) do
    with {:ok, blinded_msgs} <- parse_blinded_messages(outputs),
         :ok <- check_no_duplicate_b_primes(blinded_msgs),
         {:ok, blinded_msgs} <- validate_output_amounts(blinded_msgs, quote.amount),
         {:ok, keyset} <- get_keyset_for_quote(quote),
         # WAL BEFORE claim — mandatory durability record. If the server crashes
         # between WAL and ETS update, we have a durable record. ETS-first would lose it.
         :ok <- write_liability_wal(:tokens_minted, %{amount: quote.amount, quote_id: quote.id}),
         # Claim AFTER WAL to prevent double-mint race.
         {:ok, _claimed} <- Facade.update_quote(quote.id, &Quote.claim/1) do
      # WAL has been written — liability is recorded. From this point forward,
      # NEVER unclaim the quote back to :paid. If signing fails, the quote is
      # permanently locked. The user must request a new quote. (#C2 double-mint fix)
      case Facade.sign(blinded_msgs, keyset) do
        {:ok, signatures} ->
          record_fees_collected(quote)

          conn
          |> put_status(200)
          |> json(%{
            quote: quote.id,
            state: "PAID",
            signatures: Enum.map(signatures, &JSON.BlindSignature.encode/1)
          })

        {:error, sign_reason} ->
          # Signing failed AFTER WAL write — lock quote permanently.
          # The stale_claimed mechanism will finalize this, but we log for operator awareness.
          Logger.error(
            "MintController: signing failed for claimed quote #{truncate_id(quote.id)}: #{inspect(sign_reason)}. " <>
              "Quote remains claimed (WAL liability recorded). User must request new quote."
          )

          :telemetry.execute(
            [:minted, :mint, :signing_failed_after_wal],
            %{count: 1},
            %{quote_id: truncate_id(quote.id)}
          )

          {:error, :signing_failed}
      end
    else
      {:error, :wal_write_failed} ->
        # WAL failed BEFORE claim — no state to revert.
        {:error, :internal_error}

      error ->
        error
    end
  end

  # --- NUT-05: Melt (Withdrawal) ---

  @doc """
  POST /v1/melt/quote
  Creates a melt quote for withdrawing eCash to Lightning.
  """
  def melt_quote(_conn, %{"request" => bolt11, "unit" => "sat"})
      when is_binary(bolt11) and byte_size(bolt11) > 2000 do
    {:error, :invalid_request}
  end

  def melt_quote(conn, %{"request" => bolt11, "unit" => "sat"}) when is_binary(bolt11) do
    with {:ok, amount} <- parse_bolt11_amount(bolt11),
         {:ok, quote} <- Facade.create_melt_quote(amount, bolt11) do
      conn
      |> put_status(200)
      |> json(%{
        quote: quote.id,
        amount: amount,
        fee_reserve: quote.fee,
        state: format_quote_state(quote.status),
        expiry: DateTime.to_unix(quote.expires_at)
      })
    end
  end

  def melt_quote(_conn, _params) do
    {:error, :invalid_request}
  end

  @doc """
  POST /v1/melt/quote/:id
  Executes a melt: redeems tokens and pays the Lightning invoice.
  """
  def melt(_conn, %{"inputs" => inputs}) when is_list(inputs) and length(inputs) > 1000 do
    {:error, :batch_too_large}
  end

  def melt(conn, %{"id" => id, "inputs" => inputs} = params) when is_list(inputs) do
    # Stage 1: Get quote + check expiry + atomically transition to :paying.
    # The GenServer call serializes concurrent requests — only one can
    # transition from :invoiced to :paying; the second gets :invalid_transition.
    with {:ok, quote} <- Facade.get_quote(id),
         :ok <- check_not_expired(quote),
         {:ok, _paying} <- Facade.update_quote(id, &Quote.start_payment/1) do
      # Stage 2: Parse/validate/reserve tokens; on any failure, revert quote.
      do_melt_or_abort(conn, id, quote, inputs, params)
    else
      {:error, :not_found} -> {:error, :quote_not_found}
      {:error, :invalid_transition} -> {:error, :quote_already_in_use}
      error -> error
    end
  end

  def melt(_conn, _params) do
    {:error, :invalid_request}
  end

  # Stage 2: parse inputs, validate, and reserve tokens.
  # If anything fails before payment, abort the quote back to :invoiced.
  defp do_melt_or_abort(conn, id, quote, inputs, params) do
    with {:ok, tokens} <- parse_proofs(inputs),
         required = quote.amount + quote.fee,
         {:ok, tokens} <- validate_input_amounts(tokens, required),
         {:ok, input_keyset} <- get_keyset_for_tokens(tokens),
         {:ok, active_keyset} <- get_active_keyset(),
         {:ok, _total} <- Facade.verify_and_reserve(tokens, input_keyset) do
      ctx = %{
        id: id,
        quote: quote,
        tokens: tokens,
        keyset: input_keyset,
        active_keyset: active_keyset,
        required: required,
        params: params
      }

      do_melt_payment(conn, ctx)
    else
      error ->
        # Revert quote to :invoiced so it can be retried with valid tokens.
        Facade.update_quote(id, &Quote.abort_payment/1)
        error
    end
  end

  # Execute Lightning payment with reservation commit/release.
  # On payment success: commit reservation (burn tokens permanently).
  # On payment failure: release reservation (tokens become available again).
  #
  # WAL-backed atomicity: a :melt_started entry is written BEFORE the.
  # Lightning payment so that crash recovery can detect incomplete melts
  # and commit/release the reservation based on payment status.
  defp do_melt_payment(conn, %{id: id, quote: quote, tokens: tokens, keyset: keyset} = ctx) do
    # Cap phoenixd's routing spend at the fee the user prepaid — the
    # mint's channel balance must never subsidize routing beyond what
    # was collected. `quote.fee` was set at melt-quote time from the
    # routing_fee_estimate, so passing it through as the cap preserves
    # the "user pays their own routing" contract end-to-end.
    payment =
      Payment.new(
        bolt11: quote.bolt11,
        amount_sats: quote.amount,
        fee_limit_sats: quote.fee
      )

    secret_hashes = Enum.map(tokens, fn t -> :crypto.hash(:sha256, t.secret) end)

    # Decode the invoice's real Lightning payment_hash so recovery /
    # the SettlementResolver can query phoenixd's
    # `/payments/outgoingbyhash/{hash}` endpoint — the internal
    # `payment.id` (32-hex, not a UUID) always failed that lookup.
    ln_payment_hash =
      case LightningFacade.parse_bolt11_payment_hash(quote.bolt11) do
        {:ok, hash} -> hash
        _ -> nil
      end

    # WAL write MUST succeed before payment — it's the crash recovery anchor.
    case write_melt_wal(:melt_started, %{
           quote_id: id,
           payment_id: payment.id,
           ln_payment_hash: ln_payment_hash,
           bolt11: quote.bolt11,
           amount: quote.amount,
           secret_hashes: secret_hashes,
           keyset_id: keyset.id
         }) do
      :ok ->
        # Store melt context on the quote so the SettlementResolver can
        # commit or release tokens if the payment outcome is ambiguous.
        melt_context = %{
          payment_id: payment.id,
          ln_payment_hash: ln_payment_hash,
          tokens: tokens,
          keyset_id: keyset.id
        }

        Facade.update_quote(id, fn q -> {:ok, %{q | melt_context: melt_context}} end)
        do_execute_melt(conn, ctx, payment)

      {:error, _} ->
        Facade.release_reservation(tokens, keyset)
        Facade.update_quote(id, &Quote.abort_payment/1)
        {:error, :wal_write_failed}
    end
  end

  defp do_execute_melt(conn, %{id: id, quote: quote, tokens: tokens, keyset: keyset} = ctx, payment) do
    case LightningFacade.execute_payment_and_await(payment) do
      {:ok, result} ->
        handle_payment_settled(conn, ctx, payment, result)

      {:error, kind} = err when kind in [:settlement_timeout] ->
        mark_settlement_unknown(id, quote, :settlement_timeout)
        err

      {:error, {:settlement_unknown, reason}} ->
        # Ambiguous payment outcome from the executor (HTTP timeout,
        # transport error, task crash, 5xx from phoenixd). The payment
        # may still settle on Lightning — tokens MUST stay reserved,
        # quote MUST transition to :settlement_unknown, and the operator
        # (or a future reconciler) resolves it against phoenixd. NEVER
        # release here.
        Logger.error(
          "MintController: melt outcome unknown, quote=#{truncate_id(id)}, reason=#{inspect(reason)} — tokens HELD"
        )

        mark_settlement_unknown(id, quote, :settlement_unknown)
        {:error, :settlement_unknown}

      {:error, {:payment_exhausted, _reason} = reason} ->
        # Retry-ladder exhausted with retryable errors — every attempt
        # was a KNOWN "did not happen on Lightning" (structured phoenixd
        # error), so releasing the reservation is safe.
        Facade.release_reservation(tokens, keyset)
        Facade.update_quote(id, &Quote.abort_payment/1)
        {:error, reason}

      {:error, reason} ->
        # Any other terminal error path (definitive HTTP 4xx, pre-flight
        # validation failure) — release is safe.
        Facade.release_reservation(tokens, keyset)
        Facade.update_quote(id, &Quote.abort_payment/1)
        {:error, reason}
    end
  end

  defp mark_settlement_unknown(id, quote, kind) do
    :telemetry.execute(
      [:minted, :melt, kind],
      %{count: 1},
      %{quote_id: truncate_id(id), amount: quote.amount}
    )

    Facade.update_quote(id, &Quote.mark_settlement_unknown/1)
  end

  # Alert path for the case where phoenixd charged more routing than
  # the reserve. With `maxFeeFlatSat` now forwarded end-to-end this
  # SHOULDN'T fire — phoenixd rejects the payment before absorbing the
  # excess — so a fired alert means either the cap didn't reach the
  # node (config regression, mock bypass) or phoenixd's semantics
  # changed. Either way the operator needs to see it immediately.
  defp maybe_alert_absorbed_fee(_id, reserve, actual) when actual <= reserve, do: :ok

  defp maybe_alert_absorbed_fee(id, reserve, actual) do
    absorbed = actual - reserve

    Logger.error(
      "MintController: routing fee exceeded reserve, quote_id=#{truncate_id(id)}, " <>
        "reserve=#{reserve}, actual=#{actual}, absorbed=#{absorbed}"
    )

    :telemetry.execute(
      [:minted, :melt, :fee_absorbed],
      %{absorbed_sats: absorbed, reserve_sats: reserve, actual_sats: actual},
      %{quote_id: truncate_id(id)}
    )
  end

  defp handle_payment_settled(
         conn,
         %{
           id: id,
           quote: quote,
           tokens: tokens,
           keyset: keyset,
           active_keyset: active_keyset,
           required: required,
           params: params
         },
         payment,
         result
       ) do
    # NUT-05 routing-fee passthrough: quote.fee is the user's pre-paid
    # estimate; result.routing_fee is what Phoenixd actually paid. The
    # difference goes back as change tokens. Without this, the operator
    # silently keeps the unused buffer.
    input_total = Enum.sum(Enum.map(tokens, & &1.amount))
    denom_overpayment = input_total - required
    actual_routing_fee = Map.get(result, :routing_fee, 0) || 0
    change_total = max(0, denom_overpayment + quote.fee - actual_routing_fee)
    change_outputs = Map.get(params, "outputs", [])

    maybe_alert_absorbed_fee(id, quote.fee, actual_routing_fee)

    Logger.info(
      "MintController: melt change, quote_id=#{truncate_id(id)}, " <>
        "fee_reserve=#{quote.fee}, routing_fee=#{actual_routing_fee}, " <>
        "denom_overpayment=#{denom_overpayment}, change=#{change_total}"
    )

    # WAL-before-signing: record change token liability BEFORE signing.
    # If WAL fails, absorb the change rather than signing without a record.
    change_sigs =
      sign_change_tokens(id, change_total, change_outputs, active_keyset)

    # Payment SETTLED — now safe to commit (permanently burn tokens).
    # Retry on transient backend failures; tokens stay blocked in pending
    # table if all retries fail (fail-safe: no token resurrection).
    case commit_with_retry(tokens, keyset, @commit_retries) do
      :ok ->
        write_melt_wal(:melt_settled, %{
          quote_id: id,
          payment_id: payment.id,
          preimage: result[:preimage]
        })

        {:ok, _paid} = Facade.update_quote(id, &Quote.mark_paid/1)
        {:ok, _claimed} = Facade.update_quote(id, &Quote.claim/1)

        # No :fees_collected entry on melt — the fee_reserve is
        # passed through to Lightning routing (NUT-05 passthrough);
        # any unused buffer was already returned to the user as
        # change. The operator collects revenue only at deposit.

        conn
        |> put_status(200)
        |> json(%{state: "PAID", paid: true, change: change_sigs})

      {:error, _reason} ->
        # Payment settled but commit failed. The user's Lightning payment
        # went through — return success so they know. Tokens remain in the
        # pending table (fail-safe: no token resurrection, no double-spend).
        # Change tokens were already signed above — user gets their change.
        write_melt_wal(:melt_settled, %{
          quote_id: id,
          payment_id: payment.id,
          preimage: result[:preimage],
          commit_failed: true
        })

        # Transition the quote to :settlement_unknown so the operator's
        # resolution flow (and the SettlementResolver's periodic scan)
        # can complete the commit rather than leaving the quote stuck
        # in :paying forever.
        Facade.update_quote(id, &Quote.mark_settlement_unknown/1)

        Logger.error(
          "MintController: melt commit failed after payment settled — " <>
            "tokens held in pending, quote #{truncate_id(id)}"
        )

        :telemetry.execute(
          [:minted, :melt, :commit_failed_after_payment],
          %{count: 1},
          %{quote_id: truncate_id(id)}
        )

        conn
        |> put_status(200)
        |> json(%{state: "PAID", paid: true, change: change_sigs})
    end
  end

  defp write_melt_wal(type, payload) do
    Minted.Storage.Facade.write_wal(type, payload)
  rescue
    e ->
      Logger.error("MintController: WAL write failed for #{type}: #{inspect(e)}")
      {:error, :wal_write_failed}
  end

  # --- NUT-03: Swap ---
  # NUT-03 swap fee is intentionally 0 — input_total == output_total enforced by Swap.

  @doc """
  POST /v1/swap
  Atomic token swap: spend old tokens, sign new blinded messages.
  """
  def swap(conn, %{"inputs" => inputs, "outputs" => outputs})
      when is_list(inputs) and is_list(outputs) and
             length(inputs) <= 1000 and length(outputs) <= 1000 do
    with {:ok, tokens} <- parse_proofs(inputs),
         {:ok, blinded_msgs} <- parse_blinded_messages(outputs),
         :ok <- check_no_duplicate_secrets(tokens),
         :ok <- check_no_duplicate_b_primes(blinded_msgs),
         {:ok, input_keyset} <- get_keyset_for_tokens(tokens),
         {:ok, active_keyset} <- get_active_keyset(),
         {:ok, signatures} <- Facade.swap(tokens, blinded_msgs, input_keyset, active_keyset) do
      conn
      |> put_status(200)
      |> json(%{signatures: Enum.map(signatures, &JSON.BlindSignature.encode/1)})
    end
  end

  def swap(_conn, _params) do
    {:error, :invalid_request}
  end

  # --- NUT-07: Spend Check ---

  @doc """
  POST /v1/check
  Check if tokens are spent or unspent.
  """
  def check(conn, %{"Ys" => ys}) when is_list(ys) and length(ys) <= 1000 do
    results = Enum.map(ys, &check_token_state/1)

    case Enum.find(results, &match?({:error, _}, &1)) do
      nil ->
        states = Enum.map(results, fn {:ok, state} -> state end)
        conn |> put_status(200) |> json(%{states: states})

      {:error, _reason} ->
        {:error, :invalid_request}
    end
  end

  def check(_conn, _params) do
    {:error, :invalid_request}
  end

  # --- Private Helpers ---

  defp parse_blinded_messages(outputs) do
    results =
      Enum.reduce_while(outputs, {:ok, []}, fn output, {:ok, acc} ->
        case JSON.BlindedMessage.decode(output) do
          {:ok, parsed} ->
            msg = %Message{amount: parsed.amount, b_prime: parsed.b_prime}
            {:cont, {:ok, [msg | acc]}}

          {:error, _} ->
            {:halt, {:error, :invalid_request}}
        end
      end)

    case results do
      {:ok, msgs} -> {:ok, Enum.reverse(msgs)}
      error -> error
    end
  end

  defp parse_proofs(inputs) do
    results =
      Enum.reduce_while(inputs, {:ok, []}, fn input, {:ok, acc} ->
        case JSON.Proof.decode(input) do
          {:ok, parsed} ->
            token = %Token{
              amount: parsed.amount,
              secret: parsed.secret,
              c: parsed.c,
              keyset_id: parsed.keyset_id
            }

            {:cont, {:ok, [token | acc]}}

          {:error, _} ->
            {:halt, {:error, :invalid_request}}
        end
      end)

    case results do
      {:ok, tokens} -> {:ok, Enum.reverse(tokens)}
      error -> error
    end
  end

  defp get_active_keyset do
    case StorageFacade.get_active_keyset() do
      [store_map | _] -> Keyset.from_store_map(store_map)
      [] -> {:error, :keyset_not_found}
    end
  end

  # Resolves the keyset the quote pinned at creation. Signing an in-flight
  # quote against its pinned keyset — regardless of current-active drift —
  # is what prevents the client's cached pubkeys from mismatching the
  # signatures. Same accept rule as `get_keyset_for_tokens`: `:active` or
  # `:retired` (both hold live private keys); `:expired` cannot sign.
  defp get_keyset_for_quote(%{keyset_id: nil}), do: {:error, :quote_missing_keyset}

  defp get_keyset_for_quote(%{keyset_id: keyset_id}) do
    with {:ok, store_map} <- StorageFacade.get_keyset(keyset_id),
         {:ok, keyset} <- Keyset.from_store_map(store_map) do
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

  # Look up the keyset that signed the presented tokens. All tokens in a batch
  # must belong to the same keyset. Expired keysets (destroyed private keys)
  # are rejected early so downstream crypto doesn't encounter invalid key material.
  defp get_keyset_for_tokens([]) do
    {:error, :empty_batch}
  end

  defp get_keyset_for_tokens([%Token{keyset_id: keyset_id} | rest]) do
    if Enum.all?(rest, fn t -> t.keyset_id == keyset_id end) do
      case StorageFacade.get_keyset(keyset_id) do
        {:ok, store_map} ->
          case Keyset.from_store_map(store_map) do
            {:ok, %Keyset{status: status} = keyset} when status in [:active, :retired] -> {:ok, keyset}
            {:ok, _expired} -> {:error, :keyset_expired}
            error -> error
          end

        :not_found ->
          {:error, :keyset_not_found}
      end
    else
      {:error, :invalid_request}
    end
  end

  defp validate_output_amounts(outputs, quote_amount) do
    total = Enum.reduce(outputs, 0, fn %Message{amount: amount}, acc -> acc + amount end)

    if total == quote_amount do
      {:ok, outputs}
    else
      {:error, :amount_mismatch}
    end
  end

  defp validate_input_amounts(tokens, required_amount) do
    total = Enum.reduce(tokens, 0, fn %Token{amount: amount}, acc -> acc + amount end)

    if total >= required_amount do
      {:ok, tokens}
    else
      {:error, :insufficient_tokens}
    end
  end

  defp commit_with_retry(tokens, keyset, retries_left) do
    case Facade.commit_reservation(tokens, keyset) do
      :ok ->
        :ok

      {:error, _} when retries_left > 1 ->
        Process.sleep(@commit_retry_delay_ms)
        commit_with_retry(tokens, keyset, retries_left - 1)

      {:error, _} = error ->
        error
    end
  end

  defp check_not_expired(%Quote{} = quote) do
    if Quote.expired?(quote), do: {:error, :quote_expired}, else: :ok
  end

  defp format_quote_state(:pending), do: "UNPAID"
  defp format_quote_state(:invoiced), do: "UNPAID"
  defp format_quote_state(:paying), do: "PENDING"
  defp format_quote_state(:paid), do: "PAID"
  defp format_quote_state(:claimed), do: "ISSUED"
  defp format_quote_state(:settlement_unknown), do: "PENDING"
  defp format_quote_state(:expired), do: "EXPIRED"

  defp parse_bolt11_amount(bolt11) do
    case LightningFacade.parse_bolt11_amount(bolt11) do
      {:ok, amount} when amount > 0 -> {:ok, amount}
      {:ok, _} -> {:error, :invalid_amount}
      {:error, reason} -> {:error, {:bolt11_parse_error, reason}}
    end
  end

  # WAL-before-signing for change tokens: record liability BEFORE signing.
  # If WAL fails, absorb overpayment rather than signing without a durable record.
  defp sign_change_tokens(_id, overpayment, _outputs, _keyset)
       when overpayment <= 0,
       do: []

  defp sign_change_tokens(_id, _overpayment, change_outputs, _keyset)
       when not is_list(change_outputs) or length(change_outputs) > 1000,
       do: []

  defp sign_change_tokens(id, overpayment, change_outputs, keyset) do
    case write_melt_wal(:tokens_minted, %{
           amount: overpayment,
           keyset_id: keyset.id,
           source: :melt_change,
           quote_id: id
         }) do
      :ok ->
        sigs = compute_change_sigs(overpayment, change_outputs, keyset)

        if sigs != [] do
          EventBus.publish(%MintEvents.TokensMinted{
            amount: overpayment,
            count: length(sigs),
            timestamp: DateTime.utc_now()
          })
        end

        sigs

      {:error, reason} ->
        Logger.error(
          "MintController: change WAL write failed, overpayment absorbed " <>
            "quote=#{truncate_id(id)} amount=#{overpayment} reason=#{inspect(reason)}"
        )

        []
    end
  end

  defp compute_change_sigs(overpayment, change_outputs, keyset) do
    if overpayment > 0 and is_list(change_outputs) and change_outputs != [] do
      do_compute_change_sigs(overpayment, change_outputs, keyset)
    else
      []
    end
  end

  defp do_compute_change_sigs(_overpayment, change_outputs, _keyset) when length(change_outputs) > 1000 do
    Logger.warning(
      "MintController: change outputs exceed batch limit (#{length(change_outputs)}), overpayment absorbed"
    )

    []
  end

  defp do_compute_change_sigs(overpayment, change_outputs, keyset) do
    with {:ok, change_msgs} <- parse_blinded_messages(change_outputs),
         true <- Enum.sum(Enum.map(change_msgs, & &1.amount)) == overpayment,
         :ok <- check_no_duplicate_b_primes(change_msgs),
         {:ok, sigs} <- Facade.sign(change_msgs, keyset, publish_event: false) do
      Enum.map(sigs, &JSON.BlindSignature.encode/1)
    else
      _ ->
        Logger.error("MintController: change signing failed, overpayment absorbed")
        []
    end
  end

  # WAL write is mandatory for mints — failure blocks token issuance.
  # WAL is written BEFORE signing to guarantee durable record precedes signatures.
  defp write_liability_wal(type, payload) do
    Minted.Storage.Facade.write_wal(type, payload)
  rescue
    e ->
      Logger.error("MintController: WAL write failed for #{type}: #{inspect(e)}")
      :telemetry.execute([:minted, :wal, :write_failure], %{count: 1}, %{type: type})
      {:error, :wal_write_failed}
  end

  # Records the fee collection for the standard NUT-04 HTTP mint claim
  # path. Best-effort on the WAL — the primary durability record
  # (:tokens_minted) is written by `claim_paid_quote_inner` before
  # `Facade.sign`. A fee-WAL failure here logs and continues so the
  # signed tokens still return to the caller; the House-income
  # tracker's boot-time WAL-reconcile will pick up the WAL entries on
  # next restart if the counter is behind.
  defp record_fees_collected(%{fee: fee}) when not is_integer(fee) or fee <= 0, do: :ok

  defp record_fees_collected(quote) do
    case write_liability_wal(:fees_collected, %{amount: quote.fee, quote_id: quote.id}) do
      :ok ->
        EventBus.publish(%MintEvents.FeesCollected{
          amount: quote.fee,
          quote_id: quote.id,
          timestamp: DateTime.utc_now()
        })

      {:error, reason} ->
        Logger.error(
          "MintController: fee WAL write failed for quote #{truncate_id(quote.id)}: " <>
            "#{inspect(reason)}. House-income counter will under-report by #{quote.fee} sats."
        )
    end
  end

  defp check_no_duplicate_b_primes(blinded_msgs) do
    b_primes = Enum.map(blinded_msgs, & &1.b_prime)
    unique = MapSet.new(b_primes)

    if MapSet.size(unique) == length(b_primes) do
      :ok
    else
      {:error, :duplicate_blinded_messages}
    end
  end

  defp check_no_duplicate_secrets(tokens) do
    secrets = Enum.map(tokens, & &1.secret)
    unique = MapSet.new(secrets)

    if MapSet.size(unique) == length(secrets) do
      :ok
    else
      {:error, :duplicate_secrets}
    end
  end

  # NUT-07 Y values are SEC1-compressed secp256k1 points — 33 bytes → exactly
  # 66 hex characters. Reject anything else up front so a caller cannot push
  # the overall parser budget around by sending a handful of huge hex blobs.
  defp check_token_state(y) when is_binary(y) and byte_size(y) == 66 do
    case Base.decode16(y, case: :mixed) do
      {:ok, <<_::binary-33>> = y_bytes} ->
        state = if Facade.spent_by_y?(y_bytes), do: "SPENT", else: "UNSPENT"
        {:ok, %{"Y" => y, "state" => state, "witness" => nil}}

      _ ->
        {:error, :invalid_hex}
    end
  end

  defp check_token_state(_), do: {:error, :invalid_input}

  # Truncate identifiers in log messages to reduce information exposure.
  # Keeps enough for operator lookup without logging full values. For
  # short IDs (which should never appear in practice — quote IDs are
  # UUIDs), redact the whole value rather than logging it verbatim.
  defp truncate_id(id) when is_binary(id) and byte_size(id) > 12 do
    String.slice(id, 0, 12) <> "..."
  end

  defp truncate_id(id) when is_binary(id), do: "<#{byte_size(id)}b>"

  defp ensure_operational(conn, _opts) do
    if Minted.Guards.operational?() do
      conn
    else
      conn
      |> put_status(503)
      |> json(%{error: "service_unavailable", detail: "system is halted"})
      |> Plug.Conn.halt()
    end
  end
end
