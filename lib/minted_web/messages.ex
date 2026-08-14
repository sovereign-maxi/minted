defmodule MintedWeb.Messages do
  @moduledoc """
  Centralised user-facing strings for the wallet-facing web endpoint.
  Every flash, banner, disabled-button tooltip, panel title, and
  validation error routes through here so the mint speaks with one
  voice and copy changes happen in one file.

  Admin-facing strings do NOT belong here — the admin endpoint
  (`MintedAdminWeb`) is a separate bounded context and keeps its
  copy inline in its own LiveViews, matching the PERP WALK pattern.

  Functions of a single atom are preferred where the caller already
  has the reason atom; this keeps the call site cheap
  (`Messages.deposit_complete()`) and the audit easy
  (`grep deposit_complete` finds every site).

  Pure functions, no process state, no IO. Safe to call from any
  context: LiveView render, controllers, components.

  ## Structural rules

    * Function names lowercase snake_case, describe the STRING not the
      caller (`deposit_complete` not `on_deposit_success`)
    * Trailing period on flashes and banner bodies (full sentences)
    * NO trailing period on button labels, tooltips, badges, and
      status pills (fragments)
    * Multi-clause on a single atom for reason variants
    * Uppercase status labels (`"UNPAID"`, `"CLAIMING"`) — CSS handles
      styling, the label communicates a state at a glance
  """

  # --- Deposit + withdrawal flashes ---

  @doc "Success flash after Lightning-side settlement + mint issues tokens."
  def deposit_complete, do: "Deposit complete. Tokens minted."

  @doc "Success flash after user redeems tokens + LN payment goes out."
  def withdrawal_complete, do: "Withdrawal complete. Tokens melted."

  @doc "Error flash on melt failure — tokens are restored to the wallet."
  def withdrawal_failed_tokens_restored,
    do: "Withdrawal failed. Your tokens have been restored."

  @doc """
  Error flash on melt failure where tokens are NOT restored — a
  crash or ambiguous Lightning outcome leaves them locked in the
  mint's pending table awaiting operator reconciliation. The user
  is told the truth: their funds are safe on the mint but not yet
  back in their wallet.
  """
  def withdrawal_failed_tokens_held,
    do:
      "Withdrawal outcome unresolved. Your funds are safe on the mint but not yet returned — " <>
        "the operator will reconcile and either finish the payment or restore your tokens."

  # --- Token storage failure (deposit claim) ---
  #
  # The client reports a recoverability class with each failure:
  #
  #   :retriable     — transient (storage write/quota); reload can fix it
  #   :deterministic — verification failure; reload will fail identically
  #   :unrecoverable — blinding state lost; only operator recovery helps
  #
  # Funds are never lost at this point — the mint retains signatures —
  # so every variant leads with funds safety.

  @doc "Error flash when the client fails to store minted tokens."
  def token_storage_failed(:retriable),
    do: "Deposit claim failed. Your funds are safe — reloading the page may resolve it."

  def token_storage_failed(:deterministic),
    do: "Deposit claim failed and reloading will not fix it. Your funds are safe — see the deposit for a diagnostic."

  def token_storage_failed(:unrecoverable),
    do: "Deposit claim needs recovery. Your funds are safe on the mint — see the deposit for a diagnostic."

  @doc "Explanation shown on a failed deposit card."
  def storage_failure_explanation(:retriable),
    do:
      "Storing your tokens failed. The mint retains your signatures — reload the page to retry. " <>
        "If it keeps failing, copy the diagnostic and reach out via Session to send it to us."

  def storage_failure_explanation(:deterministic),
    do:
      "Claiming failed verification and retrying will not fix it. " <>
        "Copy the diagnostic and reach out via Session to send it to us — we can recover your funds."

  def storage_failure_explanation(:unrecoverable),
    do:
      "This browser lost the data needed to claim these tokens. " <>
        "Copy the diagnostic and reach out via Session to send it to us — your funds remain recoverable on the mint."

  @doc "Button label: copy the failure diagnostic to the clipboard."
  def action_copy_diagnostic, do: "Copy Diagnostic"

  @doc "Button label: dismiss a failed deposit card."
  def action_dismiss, do: "Dismiss"

  # --- First-visit welcome modal (phishing defense) ---
  #
  # Rendered inside `<.panel><.panel_body>` matching the deposit
  # modal chrome. Content is prose (not stat rows) — the phishing
  # defense reads as an orientation, not a data list.

  @doc "Title of the welcome/phishing-defense modal (panel header)."
  def modal_title_welcome, do: "MINTED"

  @doc "Lead line before the host code block."
  def welcome_on_host_prefix, do: "You are on:"

  @doc "Instruction to verify address bar and bookmark."
  def welcome_verify_instruction,
    do: "Verify this matches your address bar. Bookmark it. Phishing clones exist."

  @doc "Outcome-first orientation line — what the user gets, not the mechanism."
  def welcome_description, do: "Bitcoin without a trail."

  @doc "Primary action label on the welcome modal."
  def action_continue, do: "CONTINUE"
end
