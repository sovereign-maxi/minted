defmodule MintedWeb.Live.Components.BackupPanel do
  @moduledoc """
  Backup panel LiveComponent rendered inline in the right-column tab area.

  Mirrors the restore panel layout: a textarea (initially empty) and a
  button. Clicking EXPORT BACKUP fills the textarea with the cashuA
  string. Clicking inside the textarea auto-selects and copies to the
  clipboard with a flash confirmation.

  Tokens are NOT removed from the wallet on export.
  """

  use MintedWeb, :live_component

  import Minted.Format, only: [format_sats: 1]

  require Logger

  @impl true
  def mount(socket) do
    {:ok,
     assign(socket,
       token_string: "",
       exported: false,
       error: nil,
       export_count: nil,
       export_total: nil
     )}
  end

  @impl true
  def update(%{_action: :backup_result, result: {:ok, cashu_string, count, total}}, socket) do
    {:ok,
     assign(socket,
       token_string: cashu_string,
       exported: true,
       error: nil,
       export_count: count,
       export_total: total
     )}
  end

  def update(%{_action: :backup_result, result: {:error, reason}}, socket) do
    Logger.warning("BackupPanel: backup failed: #{inspect(reason)}")
    {:ok, assign(socket, error: "Backup failed. Please try again.")}
  end

  def update(assigns, socket) do
    {:ok, assign(socket, assigns)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id={@id}>
      <.field_textarea
        label="Cashu Token String"
        id="backup-token"
        content={@token_string}
        error={@error}
        hint={
          if @exported && @export_count,
            do: "#{format_sats(@export_total)} sats across #{@export_count} token#{if @export_count != 1, do: "s"}"
        }
        rows="4"
        readonly
        placeholder={if @exported, do: nil, else: "Click Export Backup to generate..."}
        phx-hook="SelectAndCopy"
      />
      <.btn phx-click="export_backup" phx-target={@myself} disabled={@balance == 0}>
        {if @exported, do: "Export Again", else: "Export Backup"}
      </.btn>
    </div>
    """
  end

  @impl true
  def handle_event("export_backup", _params, socket) do
    send(self(), {:export_backup, socket.assigns.id})
    {:noreply, assign(socket, error: nil)}
  end
end
