defmodule MintedWeb.Live.Components.RestorePanel do
  @moduledoc """
  Restore panel LiveComponent rendered inline in the right-column tab area.

  Single-view: textarea for cashuA string + SUBMIT button.
  On submit, parses and immediately fires import to parent.
  On success/failure the parent LiveView flashes the result and the panel resets.
  """

  use MintedWeb, :live_component

  require Logger

  alias Minted.Mint.Token

  @impl true
  def mount(socket) do
    {:ok,
     assign(socket,
       raw_token: "",
       processing: false,
       error: nil
     )}
  end

  @impl true
  def update(%{_action: :restore_result, result: {:ok, _stored, _skipped, _amount}}, socket) do
    {:ok, reset_state(socket)}
  end

  def update(%{_action: :restore_result, result: {:error, _reason}}, socket) do
    {:ok, reset_state(socket)}
  end

  def update(assigns, socket) do
    {:ok, assign(socket, assigns)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id={@id}>
      <form phx-submit="submit_restore" phx-change="update_token" phx-target={@myself}>
        <.field_textarea
          label="Cashu Token String"
          id="restore-token"
          name="token"
          content={@raw_token}
          error={@error}
          rows="4"
          placeholder="cashuA..."
          phx-target={@myself}
        />
        <.btn type="submit" disabled={@raw_token == "" or @processing}>
          {if @processing, do: "Restoring...", else: "Import Tokens"}
        </.btn>
      </form>
    </div>
    """
  end

  @impl true
  def handle_event("update_token", %{"token" => raw_token}, socket) do
    {:noreply, assign(socket, raw_token: String.trim(raw_token))}
  end

  def handle_event("submit_restore", %{"token" => raw_token}, socket) do
    raw_token = String.trim(raw_token)

    case Token.deserialize(raw_token) do
      {:ok, _tokens} ->
        send(self(), {:import_backup, socket.assigns.id, raw_token})
        {:noreply, assign(socket, raw_token: raw_token, processing: true, error: nil)}

      {:error, reason} ->
        Logger.warning("RestorePanel: parse backup failed: #{inspect(reason)}")
        {:noreply, assign(socket, raw_token: raw_token, error: sanitize_error(reason))}
    end
  end

  # --- Helpers ---

  defp reset_state(socket) do
    assign(socket,
      raw_token: "",
      processing: false,
      error: nil
    )
  end

  defp sanitize_error(:invalid_format), do: "Invalid format. Must be a cashuA string."
  defp sanitize_error(:backup_too_large), do: "Backup string is too large."
  defp sanitize_error(:too_many_tokens), do: "Backup contains too many tokens."
  defp sanitize_error(:invalid_proof_encoding), do: "Backup contains invalid token data."
  defp sanitize_error({:keyset_mismatch, _}), do: "Tokens were signed by a different keyset."
  defp sanitize_error(_), do: "Restore failed. Please verify your backup string."
end
