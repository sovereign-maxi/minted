defmodule MintedWeb.Live.Components.WithdrawalPanel do
  @moduledoc """
  Withdrawal panel LiveComponent rendered inline in the right-column tab area.

  Supports Lightning (bolt11 invoice) withdrawals.
  Two-step flow: paste invoice -> confirm amount + fee -> melt.
  On success/failure the parent LiveView flashes the result and the panel resets.
  """

  use MintedWeb, :live_component

  import Minted.Format, only: [format_sats: 1]

  alias Minted.Lightning.Facade, as: LightningFacade
  alias Minted.Mint.Facade, as: MintFacade

  @impl true
  def mount(socket) do
    {:ok,
     assign(socket,
       method: :lightning,
       invoice: "",
       step: :input,
       parsed_amount: nil,
       fee: nil,
       processing: false
     )}
  end

  @impl true
  def update(%{_action: :melt_result, result: {:ok, _result}}, socket) do
    {:ok, reset_state(socket)}
  end

  def update(%{_action: :melt_result, result: {:error, _reason}}, socket) do
    {:ok, reset_state(socket)}
  end

  def update(assigns, socket) do
    {:ok, assign(socket, assigns)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id={@id}>
      <%= if @step == :confirm do %>
        <div class="bp-field">
          <.stat_row label="Method" value="Lightning" />
          <.stat_row label="Amount" value={"#{format_sats(@parsed_amount)} sats"} class="accent" />
          <.stat_row label="Routing (est.)" value={"#{format_sats(@fee)} sats"} />
          <.stat_row label="Total" value={"#{format_sats(@parsed_amount + @fee)} sats"} class="accent" />
        </div>
        <div class="mt-btn-row">
          <.btn variant="muted" type="button" phx-click="cancel_confirm" phx-target={@myself}>
            Back
          </.btn>
          <.btn type="button" phx-click="confirm_melt" phx-target={@myself} disabled={@processing}>
            {if @processing, do: "Withdrawing...", else: "Confirm Withdrawal"}
          </.btn>
        </div>
      <% else %>
        <form phx-submit="submit_invoice" phx-change="update_invoice" phx-target={@myself}>
          <.field_textarea
            label="Lightning Invoice (Bolt11)"
            id="withdraw-invoice"
            name="invoice"
            content={@invoice}
            rows="4"
            placeholder="lnbc..."
            required
            phx-target={@myself}
          />
          <.btn type="submit" disabled={@invoice == ""}>
            Review Withdrawal
          </.btn>
        </form>
      <% end %>
    </div>
    """
  end

  # --- Events ---

  @impl true
  def handle_event("update_invoice", %{"invoice" => invoice}, socket) do
    # Editing the invoice invalidates the computed fee — drop back to
    # the input step so confirm can't fire with a stale fee.
    {:noreply, assign(socket, invoice: String.trim(invoice), step: :input, parsed_amount: nil, fee: nil)}
  end

  def handle_event("submit_invoice", %{"invoice" => invoice}, socket) do
    invoice = String.trim(invoice)

    case parse_bolt11_amount(invoice) do
      {:ok, amount} ->
        fee = MintFacade.withdrawal_fee(amount)

        {:noreply,
         assign(socket,
           invoice: invoice,
           step: :confirm,
           parsed_amount: amount,
           fee: fee
         )}

      {:error, reason} ->
        send(self(), {:flash, :error, reason})
        {:noreply, socket}
    end
  end

  def handle_event("confirm_melt", _params, socket) do
    send(self(), {:melt_tokens_full, socket.assigns.id, socket.assigns.invoice, socket.assigns.fee})
    {:noreply, assign(socket, processing: true)}
  end

  def handle_event("cancel_confirm", _params, socket) do
    {:noreply, assign(socket, step: :input, parsed_amount: nil, fee: nil)}
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  # --- Helpers ---

  defp reset_state(socket) do
    assign(socket,
      invoice: "",
      step: :input,
      parsed_amount: nil,
      fee: nil,
      processing: false
    )
  end

  @doc false
  def parse_bolt11_amount(""), do: {:error, "Invoice cannot be empty."}

  def parse_bolt11_amount(invoice) when is_binary(invoice) and byte_size(invoice) > 2000 do
    {:error, "Invoice too long."}
  end

  def parse_bolt11_amount(invoice) when is_binary(invoice) do
    normalized = invoice |> String.trim() |> String.downcase()

    if String.starts_with?(normalized, "lnbc") or String.starts_with?(normalized, "lntb") or
         String.starts_with?(normalized, "lnbcrt") do
      case LightningFacade.parse_bolt11_amount(normalized) do
        {:ok, 0} -> {:error, "Invoice does not specify an amount."}
        {:ok, amount} -> {:ok, amount}
        {:error, _} -> {:error, "Could not parse invoice amount."}
      end
    else
      {:error, "Invalid invoice: must start with lnbc."}
    end
  end
end
