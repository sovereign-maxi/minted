defmodule MintedWeb.WalletLive do
  @moduledoc """
  Main wallet dashboard LiveView.

  Renders all panel components in the reference 2-column layout:
  - Ticker bar (status pips + key metrics)
  - Left column: Balance, Token Inventory | Activity Feed, System Status
  - Right column: Tab bar (Deposit/Withdraw/Backup/Restore)

  Subscribes to EventBus events and dispatches `send_update/2` to child
  components so panels refresh immediately when state changes.
  """

  use MintedWeb, :live_view

  import Minted.Format, only: [format_sats: 1, short_keyset_id: 1]

  require Logger

  alias Minted.Events.EventBus
  alias Minted.Mint.Facade, as: MintFacade
  alias Minted.Mint.{Keyset, Pending, Token}
  alias Minted.Oracle.Facade, as: OracleFacade
  alias Minted.Storage.Facade, as: StorageFacade
  alias Minted.Wallet.Service
  alias MintedWeb.Live.Helpers
  alias MintedWeb.Messages

  alias MintedWeb.Live.Components.{
    ActivityFeed,
    BackupPanel,
    DepositPanel,
    RestorePanel,
    TokenCard,
    WithdrawalPanel
  }

  @component_ids %{}

  # EventBus event modules to subscribe to on mount.
  @event_subscriptions [
    Minted.Events.Mint.TokensMinted,
    Minted.Events.Mint.TokensBurned,
    Minted.Events.Mint.TokensSwapped,
    Minted.Events.Lightning.InvoicePaid,
    Minted.Events.Lightning.LiquidityLow,
    Minted.Events.Lightning.LiquidityCritical,
    Minted.Events.Lightning.LiquidityRecovered,
    Minted.Events.Reserves.ProofGenerated,
    Minted.Events.Telemetry.TorDown,
    Minted.Events.Telemetry.TorDegraded,
    Minted.Events.Telemetry.TorRecovered,
    Minted.Events.Telemetry.SystemStatusChanged,
    Minted.Events.Wallet.BalanceChanged,
    Minted.Events.Oracle.PriceUpdated
  ]

  @impl true
  def mount(_params, session, socket) do
    if connected?(socket) do
      Enum.each(@event_subscriptions, &EventBus.subscribe/1)
      Phoenix.PubSub.subscribe(Minted.PubSub, Minted.Mint.Pending.Reconciler.pubsub_topic())
    end

    # Pending entries are bound to wallet_session_id so a reconnect /
    # page reload (which gives a fresh socket.id) can still ACK or
    # request redelivery of its own signatures. The CSRF token is per
    # browser session (set at fetch_session, rotates only when the
    # cookie itself rotates) and therefore distinguishes browsers
    # without breaking same-browser retry.
    {wallet_session_id, socket} =
      case Map.get(session, "_csrf_token") do
        token when is_binary(token) ->
          {token, socket}

        _ ->
          # No session cookie (e.g. Tor Browser safest mode) — the id
          # falls back to the per-mount socket.id, so a reload orphans
          # in-flight deposits. Warn the user; the deposit stays
          # recoverable by the operator.
          {socket.id,
           put_flash(
             socket,
             :info,
             "Cookies are disabled — a page reload can orphan an in-flight deposit. Export a backup after minting."
           )}
      end

    socket =
      assign(socket,
        page_title: "MINTED - WALLET",
        balance: 0,
        tokens: [],
        activities: [],
        active_tab: :deposit,
        price_usd: fetch_price_usd(),
        health: Helpers.fetch_footer_health(),
        pending_withdrawal: nil,
        pending_mint: nil,
        wasm_status: :loading,
        reserves: Helpers.reserves_info(),
        keyset_id: Minted.Mint.Facade.active_keyset_id(),
        wallet_session_id: wallet_session_id
      )

    socket =
      if connected?(socket) do
        push_event(socket, "wallet:request_state", %{})
      else
        socket
      end

    {:ok, socket}
  end

  # --- Child component messages ---

  @impl true
  def handle_info({:flash, level, message}, socket) do
    {:noreply, put_flash(socket, level, message)}
  end

  # Reconciler aged out a pending deposit — tell the client to drop
  # any matching `_blindingStates` entry so it stops requesting
  # signatures the server no longer has.
  def handle_info({:quote_reconciled, quote_id}, socket) do
    {:noreply, push_event(socket, "wallet:quote_expired", %{quote_id: quote_id})}
  end

  def handle_info({:switch_tab, tab}, socket)
      when tab in [:deposit, :withdraw, :backup, :restore] do
    {:noreply, assign(socket, active_tab: tab)}
  end

  def handle_info({:deposit_claiming}, socket) do
    {:noreply, socket}
  end

  # --- Wallet operations — spawned as Tasks, results sent back to LiveView PID ---

  def handle_info({:claim_deposit, component_id, quote_id}, socket) do
    # Guard: if the modal was closed (quote expired), skip the claim entirely.
    # This prevents the race where poll queues {:claim_deposit} and then the
    # user closes the modal, expiring the quote.
    #
    # Ownership check: the quote MUST have been created by this browser
    # session. Any other session pushing the same quote_id — either via
    # crafted messages or a stale restore — is rejected before we push
    # signing keys back to the client.
    with {:ok, %{status: :paid} = quote} <- MintFacade.get_quote(quote_id),
         true <- quote.owner_session == socket.assigns[:wallet_session_id],
         {:ok, keyset} <- get_keyset_for_quote(quote) do
      pubkeys = encode_keyset_pubkeys(keyset)

      socket =
        socket
        |> assign(pending_mint: %{quote_id: quote_id, component_id: component_id})
        |> push_event("wallet:payment_received", %{
          quote_id: quote_id,
          amounts: quote.denomination_breakdown,
          keyset_id: keyset.id,
          keyset_keys: pubkeys
        })

      {:noreply, socket}
    else
      false ->
        Logger.warning("WalletLive: rejecting claim from foreign session, quote_id=#{quote_id}")

        {:noreply, socket}

      {:error, %{status: _} = _quote} ->
        Logger.debug("WalletLive: skipping claim, quote_id=#{quote_id}, state=not_paid")
        {:noreply, socket}

      {:error, :not_found} ->
        Logger.debug("WalletLive: skipping claim, quote_id=#{quote_id}, state=not_found")
        {:noreply, socket}

      {:error, reason} ->
        Logger.error("WalletLive: no active keyset for deposit, quote_id=#{quote_id}, reason=#{error_code(reason)}")

        send_update(DepositPanel, id: component_id, _action: :claim_result, result: {:error, reason})
        {:noreply, socket}

      _other ->
        Logger.debug("WalletLive: skipping claim, quote_id=#{quote_id}, state=not_paid")
        {:noreply, socket}
    end
  end

  def handle_info({:export_backup, component_id}, socket) do
    {:noreply,
     socket
     |> assign(pending_backup_component: component_id)
     |> push_event("wallet:request_all_tokens", %{})}
  end

  def handle_info({:import_backup, component_id, cashu_string}, socket) do
    if socket.assigns[:pending_restore_component] do
      # A restore is already running for this socket. The UI's
      # processing flag is client-side only — enforce it here, since
      # each task costs up to 10k signature verifications.
      {:noreply, socket}
    else
      lv = self()

      Task.Supervisor.start_child(Minted.TaskSupervisor, fn ->
        result = Service.import_backup(cashu_string)
        send(lv, {:task_result, RestorePanel, component_id, :restore_result, result})
      end)

      {:noreply, assign(socket, pending_restore_component: component_id)}
    end
  end

  def handle_info({:melt_tokens_full, component_id, bolt11, fee}, socket) do
    case Minted.Lightning.Facade.parse_bolt11_amount(bolt11) do
      {:ok, amount} ->
        pending = %{component_id: component_id, bolt11: bolt11, fee: fee, amount: amount}

        {:noreply,
         socket
         |> assign(pending_withdrawal: pending)
         |> push_event("wallet:select_tokens", %{amount: amount + fee})}

      {:error, reason} ->
        send_update(WithdrawalPanel, id: component_id, _action: :melt_result, result: {:error, reason})
        {:noreply, socket}
    end
  end

  # Deposit sign result — push blind signatures to client and stash them
  # so the activity log waits for the client's storage ACK. Without the
  # ACK gate, a client-side unblinding error leaves a "tokens minted"
  # activity entry but no actual tokens in localStorage — the user sees
  # phantom liability and the mint over-reports outstanding.
  def handle_info({:task_result, DepositPanel, component_id, :sign_result, quote_id, {:ok, signatures}}, socket) do
    encoded_sigs = encode_signatures_for_client(signatures)
    total_amount = Enum.sum(Enum.map(signatures, & &1.amount))

    # Durable write BEFORE the push — if the BEAM dies between this
    # call and the client receiving the event, the signatures are
    # still recoverable on next mount via `wallet:request_signatures`.
    # Bind the entry to wallet_session_id (CSRF token from the browser
    # cookie) so a reconnect or page reload — both of which assign a
    # fresh socket.id — can still ACK or request redelivery. A different
    # browser session has a different cookie and therefore a different
    # CSRF token, which still blocks the cross-session ACK attack.
    case Pending.put(quote_id, socket.assigns.wallet_session_id, %{
           signatures: signatures,
           total_amount: total_amount,
           component_id: component_id
         }) do
      :ok ->
        {:noreply,
         push_event(socket, "wallet:blind_signatures", %{
           quote_id: quote_id,
           signatures: encoded_sigs
         })}

      {:error, reason} ->
        # The mint already wrote :tokens_minted to the WAL — without
        # the Pending entry there's no path to redeliver signatures
        # to the client. Surface the failure loudly so the operator
        # is aware the liability counter has drifted by `total_amount`
        # for this quote_id.
        Logger.error(
          "WalletLive: Pending.put failed quote_id=#{quote_id} amount=#{total_amount} " <>
            "reason=#{inspect(reason)} — phantom liability recorded, manual reconciliation needed"
        )

        :telemetry.execute(
          [:minted, :wallet, :pending_put_failed],
          %{count: 1, amount: total_amount},
          %{quote_id: quote_id, reason: reason}
        )

        send_update(DepositPanel,
          id: component_id,
          _action: :claim_result,
          result: {:error, :pending_store_unavailable}
        )

        {:noreply,
         socket
         |> assign(pending_mint: nil)
         |> put_flash(:error, "Deposit failed at storage. Operator notified.")}
    end
  end

  def handle_info({:task_result, DepositPanel, component_id, :sign_result, quote_id, {:error, reason}}, socket) do
    send_update(DepositPanel, id: component_id, _action: :claim_result, result: {:error, reason})

    Logger.warning("WalletLive: sign_result error quote_id=#{quote_id} reason=#{error_code(reason)}")

    socket =
      socket
      |> assign(pending_mint: nil)
      |> put_flash(:error, "Deposit failed: #{error_code(reason)}")

    {:noreply, socket}
  end

  # Legacy deposit claim result (server-side blinding path — kept for tests/rollback).
  def handle_info({:task_result, DepositPanel, component_id, :claim_result, {:ok, tokens}}, socket) do
    send_update(DepositPanel, id: component_id, _action: :claim_result, result: {:ok, tokens})

    encoded = encode_tokens_for_client(tokens)

    socket =
      socket
      |> push_event("wallet:tokens_minted", %{tokens: encoded})
      |> push_event("wallet:add_activity", %{
        type: "deposit",
        amount: Enum.sum(Enum.map(tokens, & &1.amount)),
        tokens: length(tokens),
        status: "complete",
        at: DateTime.utc_now() |> DateTime.to_iso8601()
      })
      |> put_flash(:success, Messages.deposit_complete())

    {:noreply, socket}
  end

  # Backup result — forward to BackupPanel
  def handle_info({:task_result, BackupPanel, component_id, :backup_result, result}, socket) do
    send_update(BackupPanel, id: component_id, _action: :backup_result, result: result)

    socket =
      socket
      |> maybe_flash(:backup_result, result)

    {:noreply, socket}
  end

  # Restore result — push verified tokens to client localStorage
  def handle_info({:task_result, RestorePanel, component_id, :restore_result, {:ok, tokens, skipped, amount}}, socket) do
    send_update(RestorePanel, id: component_id, _action: :restore_result, result: {:ok, tokens, skipped, amount})

    encoded = encode_tokens_for_client(tokens)

    socket =
      socket
      |> push_event("wallet:store_verified_tokens", %{tokens: encoded})
      |> push_event("wallet:request_spent_check", %{})
      |> push_event("wallet:add_activity", %{
        type: "receive",
        amount: amount,
        tokens: length(tokens),
        status: "complete",
        at: DateTime.utc_now() |> DateTime.to_iso8601()
      })
      |> put_flash(:success, restore_flash_message(tokens, skipped, amount))
      |> assign(pending_restore_component: nil)

    {:noreply, socket}
  end

  # Melt result — remove spent tokens, add change tokens back to client localStorage
  def handle_info({:task_result, WithdrawalPanel, component_id, :melt_result, {:ok, result}}, socket) do
    send_update(WithdrawalPanel, id: component_id, _action: :melt_result, result: {:ok, result})

    secrets =
      case socket.assigns.pending_withdrawal do
        %{secrets: s} -> s
        _ -> []
      end

    change_tokens = Map.get(result, :change, [])

    socket =
      socket
      |> push_event("wallet:tokens_removed", %{secrets: secrets})
      |> then(fn s ->
        if change_tokens != [] do
          encoded = encode_tokens_for_client(change_tokens)
          push_event(s, "wallet:tokens_minted", %{tokens: encoded})
        else
          s
        end
      end)
      |> push_event("wallet:add_activity", %{
        type: "withdrawal",
        amount: result.amount,
        tokens: result.tokens_spent,
        status: "complete",
        at: DateTime.utc_now() |> DateTime.to_iso8601()
      })
      |> assign(pending_withdrawal: nil)
      |> put_flash(:success, Messages.withdrawal_complete())

    {:noreply, socket}
  end

  # Melt settlement unknown — payment may still complete. Remove tokens from
  # client (they're locked on the mint) but warn the user to check their wallet.
  def handle_info({:task_result, WithdrawalPanel, component_id, :melt_result, {:error, :settlement_unknown}}, socket) do
    send_update(WithdrawalPanel, id: component_id, _action: :melt_result, result: {:error, :settlement_unknown})

    secrets =
      case socket.assigns.pending_withdrawal do
        %{secrets: s} -> s
        _ -> []
      end

    socket =
      socket
      |> push_event("wallet:tokens_removed", %{secrets: secrets})
      |> assign(pending_withdrawal: nil)
      |> put_flash(
        :error,
        "Payment pending. Your tokens have been locked. Check your receiving wallet — the payment may still arrive."
      )

    {:noreply, socket}
  end

  # Generic handler: Task results → send_update to the target component.
  def handle_info({:task_result, module, component_id, action, result}, socket) do
    send_update(module, id: component_id, _action: action, result: result)

    socket =
      socket
      |> maybe_flash(action, result)
      |> assign(pending_restore_component: nil)

    {:noreply, socket}
  end

  # --- EventBus dispatchers — refresh child components on domain events ---

  # Mint activity changes live outstanding → reserve ratio moves.
  # Refresh the sub-nav so the ratio (and any downstream panels) stay fresh.
  def handle_info(%mod{}, socket)
      when mod in [
             Minted.Events.Mint.TokensMinted,
             Minted.Events.Mint.TokensBurned,
             Minted.Events.Mint.TokensSwapped
           ] do
    refresh(refresh_sub_nav(socket), [])
  end

  # Lightning → StatusTicker + refresh health.
  def handle_info(%Minted.Events.Lightning.InvoicePaid{} = _event, socket) do
    # Forward to DepositPanel to trigger immediate quote check
    send_update(DepositPanel, id: "deposit-tab", _action: :poll_quotes)
    {:noreply, assign(socket, health: Helpers.fetch_footer_health())}
  end

  def handle_info(%mod{}, socket)
      when mod in [
             Minted.Events.Lightning.LiquidityLow,
             Minted.Events.Lightning.LiquidityCritical,
             Minted.Events.Lightning.LiquidityRecovered
           ] do
    {:noreply, assign(socket, health: Helpers.fetch_footer_health())}
  end

  # Reserves → sub-nav + SystemStatus.
  def handle_info(%Minted.Events.Reserves.ProofGenerated{}, socket) do
    refresh(refresh_sub_nav(socket), [])
  end

  # Tor → StatusTicker + refresh health.
  def handle_info(%mod{}, socket)
      when mod in [
             Minted.Events.Telemetry.TorDown,
             Minted.Events.Telemetry.TorDegraded,
             Minted.Events.Telemetry.TorRecovered
           ] do
    {:noreply, assign(socket, health: Helpers.fetch_footer_health())}
  end

  # System health → StatusTicker + refresh health.
  def handle_info(%Minted.Events.Telemetry.SystemStatusChanged{}, socket) do
    {:noreply, assign(socket, health: Helpers.fetch_footer_health())}
  end

  # Wallet balance changed — ignored; balance now comes from client localStorage.
  def handle_info(%Minted.Events.Wallet.BalanceChanged{}, socket) do
    {:noreply, socket}
  end

  # Oracle → store price for modal USD display
  def handle_info(%Minted.Events.Oracle.PriceUpdated{price_usd: price}, socket) do
    {:noreply, assign(socket, price_usd: price)}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  defp refresh(socket, components) do
    for mod <- components, id = @component_ids[mod] do
      send_update(mod, id: id, _action: :refresh)
    end

    {:noreply, socket}
  end

  defp maybe_flash(socket, :claim_result, {:error, _reason}) do
    put_flash(socket, :error, "Deposit failed. Please try again.")
  end

  defp maybe_flash(socket, :sign_result, {:error, _reason}) do
    socket
    |> assign(pending_mint: nil)
    |> put_flash(:error, "Deposit failed. Please try again.")
  end

  defp maybe_flash(socket, :backup_result, {:ok, _str, count, total}) do
    put_flash(
      socket,
      :success,
      "Backup ready — #{format_sats(total)} sats across #{count} token#{if count != 1, do: "s"}"
    )
  end

  defp maybe_flash(socket, :restore_result, {:error, _reason}) do
    put_flash(socket, :error, "Restore failed. Please verify your backup string.")
  end

  defp maybe_flash(socket, :melt_result, {:error, reason}) do
    Logger.warning("WalletLive: withdrawal failed: #{error_code(reason)}, raw: #{inspect(reason)}")
    put_flash(socket, :error, melt_failure_message(reason))
  end

  defp maybe_flash(socket, _action, _result), do: socket

  # A crash after reservation OR an ambiguous LN outcome leaves the
  # user's tokens locked in the mint's pending table — the copy
  # cannot honestly claim "your tokens have been restored" in those
  # cases. Split the reasons: genuine "did not spend" errors keep
  # the restored copy; the unresolved/held cases get the truthful
  # "funds safe on the mint" message.
  defp melt_failure_message(:melt_crashed), do: Messages.withdrawal_failed_tokens_held()
  defp melt_failure_message(:settlement_unknown), do: Messages.withdrawal_failed_tokens_held()
  defp melt_failure_message(:settlement_timeout), do: Messages.withdrawal_failed_tokens_held()
  defp melt_failure_message({:settlement_unknown, _}), do: Messages.withdrawal_failed_tokens_held()
  defp melt_failure_message(_other), do: Messages.withdrawal_failed_tokens_restored()

  defp error_code(:not_found), do: "not_found"
  defp error_code(:keyset_inactive), do: "keyset_inactive"
  defp error_code(:keyset_not_found), do: "keyset_not_found"
  defp error_code(:insufficient_balance), do: "insufficient_balance"
  defp error_code(:invoice_expired), do: "invoice_expired"
  defp error_code(:payment_failed), do: "payment_failed"
  defp error_code(:settlement_unknown), do: "settlement_unknown"
  defp error_code(:rate_limited), do: "rate_limited"
  defp error_code(:timeout), do: "timeout"
  defp error_code(atom) when is_atom(atom), do: Atom.to_string(atom)
  defp error_code(_other), do: "unknown"

  defp restore_flash_message(tokens, skipped, amount) do
    verified = length(tokens)

    cond do
      verified == 0 && skipped > 0 ->
        "No tokens to restore — #{skipped} spent token(s) filtered out."

      skipped > 0 ->
        "Restored #{verified} token(s) for #{amount} sats. #{skipped} spent token(s) filtered out."

      true ->
        "Restored #{verified} token(s) for #{amount} sats."
    end
  end

  # --- UI events — tab switching + invoice modal ---

  @valid_tabs ~w(deposit withdraw backup restore)a

  @impl true
  def handle_event("switch_tab", %{"tab" => tab}, socket) do
    case safe_tab(tab) do
      {:ok, atom_tab} -> {:noreply, assign(socket, active_tab: atom_tab)}
      :error -> {:noreply, socket}
    end
  end

  # Total expansion budget for the pseudo-token list. Per-denomination
  # caps alone are not enough: an unbounded NUMBER of distinct
  # denominations turns one ~128 KB websocket frame into millions of
  # heap maps and OOMs the node. Legitimate wallets hold far fewer
  # tokens than this cap.
  @max_state_token_expansion 2_000

  # Client pushes wallet state (balance + denomination summary) after any localStorage change
  def handle_event("wallet:state", params, socket) do
    balance = Map.get(params, "balance", 0)
    token_count = Map.get(params, "token_count", 0)
    tokens_by_denom = Map.get(params, "tokens_by_denom", %{})
    activities = Map.get(params, "activities", [])

    case expand_tokens_by_denom(tokens_by_denom) do
      {:ok, tokens} ->
        activity_entries =
          activities
          |> Enum.take(200)
          |> Enum.map(fn a ->
            %{
              type: safe_atom(Map.get(a, "type", "unknown")),
              amount: Map.get(a, "amount", 0),
              tokens: Map.get(a, "tokens", 0),
              status: safe_atom(Map.get(a, "status", "complete")),
              at: parse_iso_datetime(Map.get(a, "at"))
            }
          end)

        {:noreply,
         assign(socket,
           balance: balance,
           tokens: tokens,
           token_count: token_count,
           activities: activity_entries
         )}

      {:error, :expansion_budget_exceeded} ->
        Logger.warning("WalletLive: wallet:state rejected — token expansion exceeds budget")
        {:noreply, socket}
    end
  end

  # Client reports WASM crypto module status (loading → ready | failed)
  def handle_event("wallet:wasm_status", %{"status" => status}, socket)
      when status in ["ready", "failed"] do
    {:noreply, assign(socket, wasm_status: String.to_existing_atom(status))}
  end

  @max_client_array 1_000

  # Client sends blinded messages after WASM blinding.
  def handle_event("wallet:blinded_messages", %{"blinded_messages" => messages}, socket)
      when not is_list(messages) or length(messages) > @max_client_array do
    Logger.warning("WalletLive: blinded_messages rejected — invalid or oversized array")
    {:noreply, socket}
  end

  def handle_event("wallet:blinded_messages", %{"quote_id" => quote_id, "blinded_messages" => messages}, socket) do
    case socket.assigns[:pending_mint] do
      %{quote_id: ^quote_id, component_id: component_id} ->
        lv = self()

        Task.Supervisor.start_child(Minted.TaskSupervisor, fn ->
          result = Service.sign_blinded_messages(quote_id, messages)
          send(lv, {:task_result, DepositPanel, component_id, :sign_result, quote_id, result})
        end)

        # Clear pending_mint so a malicious client cannot replay the same
        # event and burn CPU by triggering repeated signing tasks for one
        # quote — BDHKE is deterministic so no forgery, but we still don't
        # want an open-ended loop through the signing path.
        {:noreply, assign(socket, pending_mint: nil)}

      _ ->
        Logger.warning("WalletLive: blinded_messages for unknown quote, quote_id=#{quote_id}")
        {:noreply, socket}
    end
  end

  # Client confirms it has unblinded the signatures and stored the tokens
  # in localStorage. Only NOW do we push the activity entry — without
  # this gate, a client-side unblinding error leaves a "tokens minted"
  # entry in the activity log with no actual tokens behind it.
  #
  # The session-binding check on Pending.delete/2 is the auth boundary:
  # the entry stores the socket id of the session that initiated the
  # deposit, and only that socket can ACK it.
  def handle_event("wallet:tokens_stored_ok", %{"quote_id" => quote_id}, socket) do
    with :ok <- check_rate_limit(socket, :tokens_stored_ok),
         {:ok, %{total_amount: total_amount, signatures: signatures} = entry} <-
           Pending.get(quote_id, socket.assigns.wallet_session_id),
         :ok <- Pending.delete(quote_id, socket.assigns.wallet_session_id) do
      # Tell the deposit modal it can close — without this the user is
      # stuck staring at "claiming…" forever despite tokens having
      # already landed in their wallet. component_id was captured at
      # sign time and survives across reconnects via Pending.
      if cid = Map.get(entry, :component_id) do
        send_update(DepositPanel, id: cid, _action: :claim_result, result: {:ok, signatures})
      end

      socket =
        socket
        |> push_event("wallet:add_activity", %{
          type: "deposit",
          amount: total_amount,
          tokens: length(signatures),
          status: "complete",
          at: DateTime.utc_now() |> DateTime.to_iso8601()
        })
        |> put_flash(:success, Messages.deposit_complete())

      {:noreply, socket}
    else
      :not_found ->
        Logger.debug("WalletLive: tokens_stored_ok for unknown quote_id=#{quote_id}")
        {:noreply, socket}

      {:error, :session_mismatch} ->
        Logger.warning("WalletLive: tokens_stored_ok rejected — session mismatch for quote_id=#{quote_id}")

        {:noreply, socket}

      {:error, :rate_limited} ->
        {:noreply, socket}
    end
  end

  # Client failed to unblind or persist tokens. Keep the signatures in
  # the durable store so the user can retry (page reload, manual
  # request) without losing the deposit. NO activity entry is pushed.
  def handle_event("wallet:tokens_stored_failed", %{"quote_id" => quote_id} = params, socket) do
    case check_rate_limit(socket, :tokens_stored_failed) do
      :ok ->
        reason = Map.get(params, "reason", "unknown") |> truncate_reason()
        class = classify_storage_failure(reason)
        diagnostic = sanitize_diagnostic(Map.get(params, "diagnostic"), quote_id, reason)

        Logger.error(
          "WalletLive: tokens_stored_failed quote_id=#{quote_id} reason=#{inspect(reason)} " <>
            "class=#{class} diagnostic=#{inspect(diagnostic)} — signatures retained for retry"
        )

        # Surface the failure in the deposit panel so the card shows a
        # persistent failed state with the diagnostic, instead of only a
        # transient flash. Prefer the component_id captured at sign time
        # (survives reconnects via Pending); fall back to the canonical
        # panel id when the Pending lookup can't resolve one.
        cid =
          case Pending.get(quote_id, socket.assigns.wallet_session_id) do
            {:ok, %{component_id: cid}} when is_binary(cid) -> cid
            _ -> "deposit-tab"
          end

        send_update(DepositPanel,
          id: cid,
          _action: :claim_result,
          result: {:error, {:unblinding_failed, quote_id, class, diagnostic}}
        )

        {:noreply, put_flash(socket, :error, Messages.token_storage_failed(class))}

      {:error, :rate_limited} ->
        {:noreply, socket}
    end
  end

  # Client requests redelivery of signatures it never successfully
  # processed. Signatures survive BEAM restart in the durable Pending
  # store, so this also covers "client reloads after the server
  # restarted between sign and ACK".
  def handle_event("wallet:request_signatures", %{"quote_id" => quote_id}, socket) do
    with :ok <- check_rate_limit(socket, :request_signatures),
         {:ok, %{signatures: signatures}} <- Pending.get(quote_id, socket.assigns.wallet_session_id) do
      encoded_sigs = encode_signatures_for_client(signatures)

      Logger.info("WalletLive: re-delivering signatures for quote_id=#{quote_id}")

      {:noreply,
       push_event(socket, "wallet:blind_signatures", %{
         quote_id: quote_id,
         signatures: encoded_sigs
       })}
    else
      :not_found ->
        {:noreply, socket}

      {:error, :session_mismatch} ->
        Logger.warning("WalletLive: request_signatures rejected — session mismatch for quote_id=#{quote_id}")

        {:noreply, socket}

      {:error, :rate_limited} ->
        {:noreply, socket}
    end
  end

  # Client responds with selected tokens for withdrawal
  def handle_event("wallet:tokens_selected", %{"error" => _reason}, socket) do
    case socket.assigns.pending_withdrawal do
      %{component_id: cid} ->
        send_update(WithdrawalPanel, id: cid, _action: :melt_result, result: {:error, :insufficient_balance})
        {:noreply, assign(socket, pending_withdrawal: nil)}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("wallet:tokens_selected", %{"tokens" => client_tokens}, socket)
      when not is_list(client_tokens) or length(client_tokens) > @max_client_array do
    Logger.warning("WalletLive: tokens_selected rejected — invalid or oversized array")
    {:noreply, socket}
  end

  def handle_event("wallet:tokens_selected", %{"tokens" => client_tokens}, socket) do
    case socket.assigns.pending_withdrawal do
      %{component_id: component_id, bolt11: bolt11, fee: fee} = pending ->
        tokens = decode_tokens_from_client(client_tokens)
        secrets = Enum.map(client_tokens, & &1["secret"])
        lv = self()

        Task.Supervisor.start_child(Minted.TaskSupervisor, fn ->
          result =
            try do
              Service.melt_tokens(bolt11, fee, tokens)
            rescue
              e ->
                Logger.error("WalletLive: melt_tokens crashed", crash_reason: {e, __STACKTRACE__})
                {:error, :melt_crashed}
            end

          send(lv, {:task_result, WithdrawalPanel, component_id, :melt_result, result})
        end)

        {:noreply, assign(socket, pending_withdrawal: Map.put(pending, :secrets, secrets))}

      _ ->
        {:noreply, socket}
    end
  end

  # Client responds with all secrets for spent-checking (after restore)
  def handle_event("wallet:spent_check", %{"secrets" => secrets}, socket)
      when not is_list(secrets) or length(secrets) > @max_client_array do
    Logger.warning("WalletLive: spent_check rejected — invalid or oversized array")
    {:noreply, socket}
  end

  def handle_event("wallet:spent_check", %{"secrets" => secrets}, socket) do
    case check_rate_limit(socket, :spent_check) do
      :ok ->
        spent_secrets =
          Enum.filter(secrets, fn hex_secret ->
            case Base.decode16(hex_secret, case: :mixed) do
              {:ok, secret} -> MintFacade.spent?(secret)
              _ -> false
            end
          end)

        socket =
          if spent_secrets != [] do
            push_event(socket, "wallet:tokens_removed", %{secrets: spent_secrets})
          else
            socket
          end

        {:noreply, socket}

      {:error, :rate_limited} ->
        {:noreply, socket}
    end
  end

  # Client responds with all tokens (backup export)
  def handle_event("wallet:all_tokens", %{"tokens" => client_tokens}, socket)
      when not is_list(client_tokens) or length(client_tokens) > @max_client_array do
    Logger.warning("WalletLive: all_tokens rejected — invalid or oversized array")
    {:noreply, socket}
  end

  def handle_event("wallet:all_tokens", %{"tokens" => client_tokens}, socket) do
    tokens = decode_tokens_from_client(client_tokens)
    component_id = socket.assigns[:pending_backup_component] || "backup-tab"
    lv = self()

    Task.Supervisor.start_child(Minted.TaskSupervisor, fn ->
      result = Service.export_backup(tokens)
      send(lv, {:task_result, BackupPanel, component_id, :backup_result, result})
    end)

    {:noreply, socket}
  end

  def handle_event("stop_propagation", _params, socket) do
    {:noreply, socket}
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  defp safe_tab(tab) when is_binary(tab) do
    atom = String.to_existing_atom(tab)
    if atom in @valid_tabs, do: {:ok, atom}, else: :error
  rescue
    ArgumentError -> :error
  end

  defp fetch_price_usd do
    case OracleFacade.current_price() do
      {price, _} when is_float(price) and price > 0 -> price
      _ -> nil
    end
  rescue
    _ -> nil
  end

  # --- Footer health ---

  defp refresh_sub_nav(socket) do
    assign(socket, reserves: Helpers.reserves_info())
  end

  defp format_usd(sats, price_usd) when is_number(price_usd) and price_usd > 0 do
    usd = sats / 100_000_000 * price_usd
    :erlang.float_to_binary(usd, decimals: 2)
  end

  defp format_usd(_, _), do: "0.00"

  defp wasm_pip_status(:ready), do: :ok
  defp wasm_pip_status(:loading), do: :degraded
  defp wasm_pip_status(_), do: :offline

  # --- Render ---

  @impl true
  def render(assigns) do
    ~H"""
    <Helpers.app_header active={:wallet} />

    <.sub_nav
      health_bar={%{fill_pct: @reserves.pct, title: @reserves.title}}
      stats={[
        %{label: "Balance (sats)", value: format_sats(@balance), wrapper_class: "bp-hide-on-mobile"},
        %{label: "Balance (USD)", value: "$#{format_usd(@balance, @price_usd)}", wrapper_class: "bp-hide-on-mobile"},
        %{label: "Keyset", value: short_keyset_id(@keyset_id)}
      ]}
    />

    <main class="bp-root" id="wallet-bridge" phx-hook="WalletBridge">
      <h1 class="bp-sr-only">Wallet</h1>
      <div class="bp-page">
        <.announcements items={Helpers.announcements()} />

        <.grid cols="wallet">
          <%!-- Left column: My Wallet (with balance), Activity — stacked vertically --%>
          <div>
            <.panel title="My Wallet">
              <:header_action>
                <span class="mt-activity-icon ok">
                  {format_sats(@balance)} sats{if @price_usd, do: " (~$#{format_usd(@balance, @price_usd)})", else: ""}
                </span>
              </:header_action>
              <.panel_scroll>
                <.live_component module={TokenCard} id="tokens" tokens={@tokens} />
              </.panel_scroll>
            </.panel>

            <.panel title="Activity">
              <.panel_scroll>
                <.live_component module={ActivityFeed} id="activity" activities={@activities} />
              </.panel_scroll>
            </.panel>
          </div>

          <%!-- Right column: Actions, spans full height --%>
          <div class="bp-box">
            <.tabs
              label="Wallet actions"
              tabs={[
                %{id: :deposit, label: "Deposit"},
                %{id: :withdraw, label: "Withdraw"},
                %{id: :backup, label: "Backup"},
                %{id: :restore, label: "Restore"}
              ]}
              active={@active_tab}
            />
            <div
              class="bp-panel-body"
              role="tabpanel"
              id={"tabpanel-#{@active_tab}"}
              aria-labelledby={"tab-#{@active_tab}"}
              tabindex="0"
            >
              <p class="bp-tab-desc">{tab_description(@active_tab)}</p>
              <%= case @active_tab do %>
                <% :deposit -> %>
                  <.live_component module={DepositPanel} id="deposit-tab" owner_session={@wallet_session_id} />
                <% :withdraw -> %>
                  <.live_component module={WithdrawalPanel} id="withdraw-tab" />
                <% :backup -> %>
                  <.live_component module={BackupPanel} id="backup-tab" balance={@balance} />
                <% :restore -> %>
                  <.live_component module={RestorePanel} id="restore-tab" />
              <% end %>
            </div>
          </div>
        </.grid>
      </div>

      <.footer
        pips={[
          %{label: "Tor", status: Helpers.pip_status(@health.tor)},
          %{label: "Lightning", status: Helpers.pip_status(@health.lightning)},
          %{label: "Crypto", status: wasm_pip_status(@wasm_status)}
        ]}
        commit_hash={Minted.Version.git_sha()}
      />
    </main>
    """
  end

  defp tab_description(:deposit),
    do: "Deposit Bitcoin via Lightning. Receive blind-signed bearer tokens. Fees shown before you pay."

  defp tab_description(:withdraw),
    do: "Withdraw Bitcoin via Lightning. Paste an invoice. The recipient cannot link the payment to you."

  defp tab_description(:backup),
    do:
      "Export your tokens as a cashuA string. This string is the money — whoever holds it, owns it. Store it anywhere. Send it to someone as a transfer of value."

  defp tab_description(:restore),
    do:
      "Paste a cashuA token string from a backup or received from someone else. Tokens will be verified against the mint and added to your balance."

  # --- Token encoding for client-side storage ---

  defp encode_tokens_for_client(tokens) do
    Enum.map(tokens, fn %Token{} = t ->
      %{
        "amount" => t.amount,
        "secret" => Base.encode16(t.secret, case: :lower),
        "C" => Base.encode16(t.c, case: :lower),
        "id" => t.keyset_id
      }
    end)
  end

  defp decode_tokens_from_client(maps) when is_list(maps) do
    Enum.flat_map(maps, fn m ->
      amount = m["amount"]

      with true <- is_integer(amount) and amount > 0,
           true <- Token.valid_denomination?(amount),
           {:ok, secret} <- decode_hex(m["secret"]),
           {:ok, c} <- decode_hex(m["C"]) do
        [
          %Token{
            amount: amount,
            secret: secret,
            c: c,
            keyset_id: m["id"]
          }
        ]
      else
        _ -> []
      end
    end)
  end

  defp decode_hex(hex) when is_binary(hex), do: Base.decode16(hex, case: :mixed)
  defp decode_hex(_), do: :error

  @allowed_activity_types ~w(deposit withdrawal receive send)
  @allowed_statuses ~w(complete pending failed)

  defp safe_atom(str) when str in @allowed_activity_types, do: String.to_existing_atom(str)
  defp safe_atom(str) when str in @allowed_statuses, do: String.to_existing_atom(str)
  defp safe_atom(_), do: :unknown

  defp parse_iso_datetime(str) when is_binary(str) do
    case DateTime.from_iso8601(str) do
      {:ok, dt, _} -> dt
      _ -> DateTime.utc_now()
    end
  end

  defp parse_iso_datetime(_), do: DateTime.utc_now()

  # --- Keyset + Signature Encoding Helpers ---

  # Resolves the keyset the quote pinned at creation. `:active` or
  # `:retired` are both fine for signing an in-flight quote (both have
  # live private keys); `:expired` is not — its keys were destroyed.
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

  defp encode_keyset_pubkeys(keyset) do
    keyset
    |> Keyset.public_keys()
    |> Map.new(fn {denom, pk} -> {to_string(denom), Base.encode16(pk, case: :lower)} end)
  end

  defp encode_signatures_for_client(signatures) do
    Enum.map(signatures, fn sig ->
      base = %{
        "amount" => sig.amount,
        "c_prime" => Base.encode16(sig.c_prime, case: :lower),
        "keyset_id" => sig.keyset_id
      }

      case sig.dleq do
        %{e: e, s: s} ->
          Map.put(base, "dleq", %{
            "e" => Base.encode16(e, case: :lower),
            "s" => Base.encode16(s, case: :lower)
          })

        _ ->
          base
      end
    end)
  end

  # --- Per-socket rate limiting for the deposit-ACK handlers ---

  # Each handler family gets a token bucket of `@rate_limit_max` per
  # `@rate_limit_window_ms`. Bucket lives in the socket's process
  # dictionary because it's per-LiveView, ephemeral, and never read
  # outside the rate-limit check itself. Using process dictionary
  # avoids dragging an extra assign into every render.
  @rate_limit_window_ms 1_000
  @rate_limit_max 30

  defp check_rate_limit(_socket, kind) do
    now = System.monotonic_time(:millisecond)
    key = {:rl, kind}
    bucket = Process.get(key, [])
    fresh = Enum.filter(bucket, fn ts -> now - ts < @rate_limit_window_ms end)

    if length(fresh) >= @rate_limit_max do
      {:error, :rate_limited}
    else
      Process.put(key, [now | fresh])
      :ok
    end
  end

  # Build pseudo-token list from the denomination map for TokenInventory
  # display. Per-denomination caps bound count/value; the overall budget
  # bounds the TOTAL number of expanded entries.
  defp expand_tokens_by_denom(tokens_by_denom) when is_map(tokens_by_denom) do
    Enum.reduce_while(tokens_by_denom, {:ok, []}, fn {denom_str, count}, {:ok, acc} ->
      with {amount, ""} <- Integer.parse(denom_str),
           true <- amount > 0 and amount <= 1_048_576,
           true <- is_integer(count) and count > 0 and count <= 1_000,
           true <- length(acc) + count <= @max_state_token_expansion do
        {:cont, {:ok, acc ++ for(_ <- 1..count, do: %{amount: amount})}}
      else
        _ -> {:halt, {:error, :expansion_budget_exceeded}}
      end
    end)
  end

  defp expand_tokens_by_denom(_other), do: {:ok, []}

  # Cap the reason field length — a malicious client can otherwise
  # blow up log volume by sending megabyte-long failure reasons.
  defp truncate_reason(reason) when is_binary(reason) do
    if byte_size(reason) > 200, do: binary_part(reason, 0, 200) <> "...", else: reason
  end

  defp truncate_reason(other), do: inspect(other) |> truncate_reason()

  # Recoverability class for a client storage-failure reason:
  #   :retriable     — transient; a reload can genuinely fix it
  #   :deterministic — reloading replays the same inputs and fails again
  #   :unrecoverable — blinding factors are gone; unblinding is
  #                    mathematically impossible, operator recovery only
  defp classify_storage_failure("no_blinding_state"), do: :unrecoverable
  defp classify_storage_failure("redelivery_exhausted"), do: :unrecoverable
  defp classify_storage_failure("signature_count_mismatch"), do: :deterministic
  defp classify_storage_failure("no_pubkey_for_amount_" <> _), do: :deterministic
  defp classify_storage_failure("dleq_verification_failed_index_" <> _), do: :deterministic
  defp classify_storage_failure(_), do: :retriable

  @diagnostic_keys ~w(reason quote_id at wasm keyset_id item_count items_with_secret
                      items_with_r items_with_b_prime sig_count sigs_with_c_prime
                      sigs_with_dleq retries ua)

  # Whitelist + type-check the client-supplied diagnostic before it is
  # logged and rendered into the copy-diagnostic button. Contains only
  # counts and status strings — never secrets, blinding factors, or
  # proofs — so the blob stays safe to paste in public channels.
  defp sanitize_diagnostic(diagnostic, quote_id, reason) do
    client =
      case diagnostic do
        %{} = map ->
          map
          |> Map.take(@diagnostic_keys)
          |> Map.new(fn
            {k, v} when is_integer(v) -> {k, v}
            {k, v} when is_binary(v) -> {k, truncate_reason(v)}
            {k, _v} -> {k, nil}
          end)

        _ ->
          %{}
      end

    Map.merge(client, %{
      "quote_id" => truncate_reason(quote_id),
      "reason" => reason,
      "server_at" => DateTime.utc_now() |> DateTime.to_iso8601()
    })
  end
end
