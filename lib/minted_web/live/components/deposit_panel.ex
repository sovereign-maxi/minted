defmodule MintedWeb.Live.Components.DepositPanel do
  @moduledoc """
  Deposit panel LiveComponent with inline in-flight deposit display.

  Shows the amount input form for Lightning deposits.
  When a quote is created, the invoice appears inline below
  the form as a compact box with QR code, copy button, and status.
  Multiple in-flight deposits can stack.

  On page reload, active quotes are restored from the Quotes service.
  """

  use MintedWeb, :live_component

  require Logger

  import Minted.Format, only: [format_sats: 1]

  alias Minted.Lightning.Facade, as: LightningFacade
  alias Minted.Mint.Facade, as: MintFacade
  alias Minted.Mint.Quote
  alias MintedWeb.Messages

  @poll_interval_ms 3_000
  @min_deposit_lightning 1_000
  @quote_cooldown_ms 5_000

  # --- Lifecycle ---

  @impl true
  def update(%{_action: :poll_quotes} = _assigns, socket) do
    now = DateTime.utc_now()

    {in_flight, failed_count} =
      Enum.map_reduce(socket.assigns.in_flight, 0, fn
        # Failed cards are terminal — re-claiming would replay the same
        # failure and spam flashes every poll tick. They leave the list
        # only via dismiss_failed or a successful claim clearing all.
        %{status: :failed} = deposit, fails ->
          {deposit, fails}

        deposit, fails ->
          # Recompute remaining seconds each poll. Storing it on the
          # deposit map (rather than deriving it from expires_at at
          # render time via DateTime.utc_now()) makes the assign
          # structurally change every 3s, which is what LiveView's
          # change tracking needs to actually re-render the countdown.
          deposit = Map.put(deposit, :remaining_seconds, remaining_seconds(deposit.expires_at, now))

          case MintFacade.get_quote(deposit.quote_id) do
            {:ok, %{status: :paid}} ->
              send(self(), {:deposit_claiming})
              send(self(), {:claim_deposit, socket.assigns.id, deposit.quote_id})
              {%{deposit | status: :claiming}, fails}

            {:ok, %{status: :expired}} ->
              {%{deposit | status: :expired}, fails + 1}

            _ ->
              {deposit, fails}
          end
      end)

    if failed_count > 0 do
      send(self(), {:flash, :error, "Deposit failed or expired. No funds were taken."})
    end

    in_flight = Enum.reject(in_flight, &(&1.status == :expired))

    socket = assign(socket, in_flight: in_flight)

    if Enum.any?(in_flight, &(&1.status != :failed)) do
      schedule_poll(socket)
    end

    {:ok, socket}
  end

  def update(%{_action: :cancel_deposit} = _assigns, socket) do
    {:ok, assign(socket, in_flight: [])}
  end

  def update(%{_action: :claim_result, result: {:ok, _tokens}}, socket) do
    {:ok, assign(socket, in_flight: [])}
  end

  # Client-side unblinding/storage failure: keep the card, mark it
  # failed, and auto-open its modal so the explanation + diagnostic are
  # in front of the user. Signatures stay in Mint.Pending server-side.
  def update(%{_action: :claim_result, result: {:error, {:unblinding_failed, quote_id, class, diagnostic}}}, socket) do
    in_flight = mark_failed(socket.assigns.in_flight, quote_id, class, diagnostic)
    {:ok, assign(socket, in_flight: in_flight, expanded_id: quote_id)}
  end

  def update(%{_action: :claim_result, result: {:error, _reason}}, socket) do
    {:ok, assign(socket, in_flight: [])}
  end

  def update(assigns, socket) do
    socket =
      socket
      |> assign(assigns)
      |> assign_new(:deposit_amount, fn -> "" end)
      |> assign_new(:method, fn -> :lightning end)
      |> assign_new(:expanded_id, fn -> nil end)
      |> assign_new(:in_flight, fn -> restore_active_deposits(assigns[:owner_session]) end)

    socket =
      if socket.assigns.in_flight != [] && !Map.get(socket.assigns, :polling_started) do
        socket
        |> assign(:polling_started, true)
        |> schedule_poll()
      else
        socket
      end

    {:ok, socket}
  end

  # --- Events ---

  @impl true
  def handle_event("validate_deposit", params, socket) do
    socket =
      socket
      |> assign(:deposit_amount, params["amount"] || socket.assigns.deposit_amount)

    {:noreply, socket}
  end

  def handle_event("request_quote", params, socket) do
    now = System.monotonic_time(:millisecond)

    case Map.get(socket.assigns, :last_quote_at) do
      nil ->
        do_request_quote(params, assign(socket, last_quote_at: now))

      last when now - last < @quote_cooldown_ms ->
        send(self(), {:flash, :error, "Please wait a few seconds before requesting another quote."})
        {:noreply, socket}

      _last ->
        do_request_quote(params, assign(socket, last_quote_at: now))
    end
  end

  def handle_event("toggle_expand", %{"id" => id}, socket) do
    new_id = if socket.assigns.expanded_id == id, do: nil, else: id
    {:noreply, assign(socket, expanded_id: new_id)}
  end

  def handle_event("toggle_expand", _params, socket) do
    {:noreply, assign(socket, expanded_id: nil)}
  end

  def handle_event("cancel_deposit", %{"id" => quote_id}, socket) do
    # Only allow cancellation of quotes owned by THIS session — i.e.
    # ones that appear in the socket's in-flight list. Without this
    # check, any client with a random quote_id could expire another
    # user's in-flight deposit (UUID-random guards against guessing
    # but not against a leaked ID via URL, screenshot, or clipboard
    # snoop). The check is O(n) on the socket's own list, not a DB
    # lookup.
    if Enum.any?(socket.assigns.in_flight, &(&1.quote_id == quote_id)) do
      MintFacade.update_quote(quote_id, &Quote.expire/1)
      in_flight = Enum.reject(socket.assigns.in_flight, &(&1.quote_id == quote_id))
      {:noreply, assign(socket, in_flight: in_flight)}
    else
      Logger.warning("DepositPanel: cancel_deposit for unknown quote_id=#{quote_id} — ignoring")
      {:noreply, socket}
    end
  end

  # Remove a failed card from the list. Deliberately does NOT expire
  # the quote — the mint retains the signatures for operator recovery.
  def handle_event("dismiss_failed", %{"id" => quote_id}, socket) do
    in_flight =
      Enum.reject(socket.assigns.in_flight, &(&1.quote_id == quote_id && &1.status == :failed))

    expanded_id = if socket.assigns.expanded_id == quote_id, do: nil, else: socket.assigns.expanded_id
    {:noreply, assign(socket, in_flight: in_flight, expanded_id: expanded_id)}
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  # --- Quote Creation ---

  defp do_request_quote(params, socket) do
    amount_str = params["amount"] || socket.assigns.deposit_amount
    amount = parse_amount(amount_str)
    min = min_deposit(socket.assigns.method)

    if amount >= min do
      create_lightning_deposit(amount, socket)
    else
      send(self(), {:flash, :error, "Minimum deposit is #{format_sats(min)} sats."})
      {:noreply, socket}
    end
  end

  defp create_lightning_deposit(amount, socket) do
    with {:ok, quote} <- MintFacade.create_mint_quote(amount, socket.assigns[:owner_session]),
         {:ok, invoice} <-
           LightningFacade.create_invoice(amount + quote.fee, "cashu mint",
             quote_id: quote.id,
             expiry_seconds: DateTime.diff(quote.expires_at, DateTime.utc_now())
           ),
         {:ok, updated_quote} <-
           MintFacade.update_quote(quote.id, &Quote.attach_invoice(&1, invoice.bolt11)) do
      add_in_flight(socket, %{
        quote_id: updated_quote.id,
        method: :lightning,
        amount: amount,
        fee: quote.fee,
        request: updated_quote.invoice,
        status: :waiting,
        expires_at: updated_quote.expires_at,
        remaining_seconds: remaining_seconds(updated_quote.expires_at, DateTime.utc_now())
      })
    else
      {:error, reason} ->
        Logger.warning("DepositPanel: Lightning quote failed: #{inspect(reason)}")
        send(self(), {:flash, :error, "Could not create quote. Please try again."})
        {:noreply, socket}
    end
  end

  defp mark_failed(in_flight, quote_id, class, diagnostic) do
    if Enum.any?(in_flight, &(&1.quote_id == quote_id)) do
      Enum.map(in_flight, fn
        %{quote_id: ^quote_id} = deposit ->
          deposit
          |> Map.put(:status, :failed)
          |> Map.merge(%{failure_class: class, diagnostic: diagnostic})

        deposit ->
          deposit
      end)
    else
      # The card is gone (page reload, tab switch) but the failure still
      # needs a surface — insert a card so the diagnostic is reachable.
      [failed_stub(quote_id, class, diagnostic) | in_flight]
    end
  end

  defp failed_stub(quote_id, class, diagnostic) do
    base = %{
      quote_id: quote_id,
      method: :lightning,
      amount: 0,
      fee: 0,
      request: nil,
      status: :failed,
      expires_at: nil,
      remaining_seconds: nil,
      failure_class: class,
      diagnostic: diagnostic
    }

    case MintFacade.get_quote(quote_id) do
      {:ok, quote} -> %{base | amount: quote.amount, fee: quote.fee}
      _ -> base
    end
  end

  defp add_in_flight(socket, deposit) do
    socket =
      socket
      |> assign(
        deposit_amount: "",
        in_flight: [deposit | socket.assigns.in_flight],
        expanded_id: deposit.quote_id
      )
      |> schedule_poll()

    {:noreply, socket}
  end

  # --- Render ---

  @impl true
  def render(assigns) do
    ~H"""
    <div id={@id}>
      <form id="deposit-form" phx-change="validate_deposit" phx-submit="request_quote" phx-target={@myself}>
        <.field_input
          label="Amount"
          badge="sats"
          type="number"
          id="deposit-amount"
          name="amount"
          placeholder={to_string(min_deposit(@method))}
          value={@deposit_amount}
          min={to_string(min_deposit(@method))}
          required
          autofocus
        />
        <.btn type="submit">
          Generate Invoice
        </.btn>
      </form>

      <%!-- Compact in-flight summary --%>
      <ul :if={@in_flight != []} class="mt-3">
        <li
          :for={deposit <- @in_flight}
          class="bp-stat-row bp-clickable"
          role="button"
          tabindex="0"
          phx-click="toggle_expand"
          phx-value-id={deposit.quote_id}
          phx-target={@myself}
        >
          <span class="bp-stat-label">
            <span aria-label="Lightning">{method_icon(deposit.method)}</span> {format_sats(deposit.amount)} sats
          </span>
          <span class={"mt-activity-icon #{status_class(deposit.status)}"}>
            {status_label(deposit.status)}
          </span>
        </li>
      </ul>

      <%!-- Modal for selected deposit --%>
      <%= if @expanded_id do %>
        <% deposit = Enum.find(@in_flight, &(&1.quote_id == @expanded_id)) %>
        <%= if deposit do %>
          <.modal on_close="toggle_expand" labelledby={"deposit-modal-title-#{deposit.quote_id}"}>
            <.panel title="Deposit" title_id={"deposit-modal-title-#{deposit.quote_id}"}>
              <.panel_body>
                <.stat_row :if={deposit.amount > 0} label="Amount" value={"#{format_sats(deposit.amount)} sats"} />
                <.stat_row :if={deposit.fee > 0} label="Fee" value={"#{format_sats(deposit.fee)} sats"} />
                <.stat_row label="Method" value="Lightning" />
                <.stat_row
                  :if={deposit.expires_at && deposit.status != :failed}
                  label="Expires"
                  value={format_remaining(deposit.remaining_seconds)}
                />
                <div class="bp-stat-row">
                  <span class="bp-stat-label">Status</span>
                  <span class={"mt-activity-icon #{status_class(deposit.status)}"}>{status_label(deposit.status)}</span>
                </div>
                <%= if deposit.status == :failed do %>
                  <p class="bp-tab-desc mt-3">{Messages.storage_failure_explanation(deposit.failure_class)}</p>
                  <div :if={is_map(deposit.diagnostic) and deposit.diagnostic != %{}} class="mt-3">
                    <div :for={{k, v} <- diagnostic_rows(deposit.diagnostic)} class="bp-stat-row">
                      <span class="bp-stat-label">{k}</span>
                      <span class="bp-stat-value">{v}</span>
                    </div>
                  </div>
                  <div class="bp-modal-actions">
                    <.btn
                      type="button"
                      id={"diag-#{deposit.quote_id}"}
                      phx-hook="CopyClipboard"
                      data-clipboard-text={Jason.encode!(deposit.diagnostic)}
                      data-select-target=""
                    >
                      {Messages.action_copy_diagnostic()}
                    </.btn>
                    <.btn
                      variant="muted"
                      type="button"
                      phx-click="dismiss_failed"
                      phx-value-id={deposit.quote_id}
                      phx-target={@myself}
                    >
                      {Messages.action_dismiss()}
                    </.btn>
                  </div>
                <% else %>
                  <div
                    class="mt-qr-container"
                    id={"mt-qr-#{deposit.quote_id}"}
                    phx-hook="QRCode"
                    data-lnurl={deposit.request}
                    phx-update="ignore"
                  >
                  </div>
                  <div class="bp-modal-actions">
                    <.btn
                      type="button"
                      id={"copy-#{deposit.quote_id}"}
                      phx-hook="CopyClipboard"
                      data-clipboard-text={deposit.request}
                      data-select-target=""
                    >
                      Copy
                    </.btn>
                    <.btn
                      :if={deposit.status == :waiting}
                      variant="muted"
                      type="button"
                      phx-click="cancel_deposit"
                      phx-value-id={deposit.quote_id}
                      phx-target={@myself}
                    >
                      Cancel
                    </.btn>
                  </div>
                <% end %>
              </.panel_body>
            </.panel>
          </.modal>
        <% end %>
      <% end %>
    </div>
    """
  end

  # --- Helpers ---

  defp schedule_poll(socket) do
    send_update_after(
      __MODULE__,
      [id: socket.assigns.id, _action: :poll_quotes],
      @poll_interval_ms
    )

    socket
  end

  defp parse_amount(str) when is_binary(str) do
    case Integer.parse(str) do
      {n, _} when n > 0 -> n
      _ -> 0
    end
  end

  defp parse_amount(_), do: 0

  defp min_deposit(_), do: @min_deposit_lightning

  # `owner_session` is the `wallet_session_id` (CSRF-token derived) that
  # WalletLive passes into this component's assigns. A `nil` or empty
  # owner returns `[]`, so a component mounted without a session sees no
  # quotes at all rather than the global list.
  defp restore_active_deposits(owner_session) do
    now = DateTime.utc_now()

    MintFacade.find_active_mint_quotes_for_owner(owner_session)
    |> Enum.map(fn quote ->
      %{
        quote_id: quote.id,
        method: Map.get(quote, :method, :lightning),
        amount: quote.amount,
        fee: quote.fee,
        request: quote.invoice,
        status: if(quote.status == :paid, do: :claiming, else: :waiting),
        expires_at: quote.expires_at,
        remaining_seconds: remaining_seconds(quote.expires_at, now)
      }
    end)
  rescue
    _ -> []
  end

  defp method_icon(_), do: "⚡"

  defp remaining_seconds(nil, _now), do: nil

  defp remaining_seconds(%DateTime{} = expires_at, %DateTime{} = now) do
    max(0, DateTime.diff(expires_at, now, :second))
  end

  defp format_remaining(nil), do: "--"

  defp format_remaining(seconds) when is_integer(seconds) do
    m = div(seconds, 60)
    s = rem(seconds, 60)
    "#{String.pad_leading(to_string(m), 2, "0")}:#{String.pad_leading(to_string(s), 2, "0")}"
  end

  defp status_label(:waiting), do: "UNPAID"
  defp status_label(:claiming), do: "CLAIMING"
  defp status_label(:expired), do: "EXPIRED"
  defp status_label(:failed), do: "FAILED"
  defp status_label(_), do: "..."

  defp status_class(:waiting), do: "warning"
  defp status_class(:claiming), do: "ok"
  defp status_class(:expired), do: "warning"
  defp status_class(:failed), do: "critical"
  defp status_class(_), do: ""

  # Diagnostic map → sorted list of {label, value} pairs for inline
  # rendering. Content is already whitelisted upstream by
  # WalletLive.sanitize_diagnostic/3, so any value here is safe to display.
  defp diagnostic_rows(diagnostic) when is_map(diagnostic) do
    diagnostic
    |> Enum.reject(fn {_k, v} -> is_nil(v) or v == "" end)
    |> Enum.map(fn {k, v} -> {to_string(k), format_diagnostic_value(v)} end)
    |> Enum.sort_by(fn {k, _v} -> k end)
  end

  defp diagnostic_rows(_), do: []

  defp format_diagnostic_value(v) when is_binary(v), do: v
  defp format_diagnostic_value(v) when is_integer(v), do: Integer.to_string(v)
  defp format_diagnostic_value(v) when is_boolean(v), do: to_string(v)
  defp format_diagnostic_value(v), do: inspect(v)
end
