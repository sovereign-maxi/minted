defmodule MintedWeb.FallbackController do
  @moduledoc """
  Centralized error handling mapping domain errors to HTTP status codes.

  Controllers declare `action_fallback MintedWeb.FallbackController` and
  return `{:error, reason}` tuples for error cases.

  Error codes:
  - 10xxx: Mint errors
  - 20xxx: Melt errors
  - 30xxx: Swap errors
  - 40xxx: General errors
  """

  use Phoenix.Controller, formats: [:json]

  import Plug.Conn

  # --- 400 Bad Request ---

  def call(conn, {:error, :invalid_amount}) do
    json_error(conn, 400, "Invalid amount", 10_001)
  end

  def call(conn, {:error, :below_minimum}) do
    json_error(conn, 400, "Amount below minimum", 10_002)
  end

  def call(conn, {:error, :above_maximum}) do
    json_error(conn, 400, "Amount above maximum", 10_003)
  end

  def call(conn, {:error, :invalid_signature}) do
    json_error(conn, 400, "Invalid token signature", 10_004)
  end

  def call(conn, {:error, :value_mismatch}) do
    json_error(conn, 400, "Input value does not equal output value", 30_001)
  end

  # Q1: Updated to match new nested 2-tuple format from SwapService.
  def call(conn, {:error, {:amount_mismatch, _input, _output}}) do
    json_error(conn, 400, "Input value does not equal output value", 30_001)
  end

  def call(conn, {:error, :empty_batch}) do
    json_error(conn, 400, "Empty token batch", 10_005)
  end

  def call(conn, {:error, :empty_swap}) do
    json_error(conn, 400, "Empty swap: inputs and outputs required", 30_002)
  end

  def call(conn, {:error, :invalid_request}) do
    json_error(conn, 400, "Malformed request body", 40_001)
  end

  def call(conn, {:error, :duplicate_blinded_messages}) do
    json_error(conn, 400, "Duplicate blinded messages", 10_008)
  end

  def call(conn, {:error, :batch_too_large}) do
    json_error(conn, 400, "Batch too large", 40_003)
  end

  def call(conn, {:error, :denomination_not_found}) do
    json_error(conn, 400, "Unknown denomination", 10_006)
  end

  def call(conn, {:error, :invalid_transition}) do
    json_error(conn, 400, "Invalid state transition", 40_002)
  end

  def call(conn, {:error, :insufficient_tokens}) do
    json_error(conn, 400, "Insufficient token value", 10_007)
  end

  def call(conn, {:error, :invalid_bolt11}) do
    json_error(conn, 400, "Invalid Lightning invoice", 20_010)
  end

  def call(conn, {:error, {:bolt11_parse_error, _reason}}) do
    json_error(conn, 400, "Invalid Lightning invoice", 20_011)
  end

  def call(conn, {:error, :keyset_not_active}) do
    json_error(conn, 400, "Keyset is not active", 10_012)
  end

  def call(conn, {:error, :payment_not_verified}) do
    json_error(conn, 400, "Payment not verified for this quote", 10_013)
  end

  # --- 404 Not Found ---

  def call(conn, {:error, :not_found}) do
    json_error(conn, 404, "Not found", 40_004)
  end

  def call(conn, {:error, :quote_not_found}) do
    json_error(conn, 404, "Quote not found", 10_010)
  end

  def call(conn, {:error, :keyset_not_found}) do
    json_error(conn, 404, "Keyset not found", 10_011)
  end

  # --- 409 Conflict ---

  def call(conn, {:error, :already_spent}) do
    escalate_double_spend(conn)
    json_error(conn, 409, "Token already spent", 10_020)
  end

  def call(conn, {:error, :double_spend, _hashes}) do
    escalate_double_spend(conn)
    json_error(conn, 409, "Token already spent", 10_020)
  end

  def call(conn, {:error, :double_spend}) do
    escalate_double_spend(conn)
    json_error(conn, 409, "Token already spent", 10_020)
  end

  # --- 410 Gone ---

  def call(conn, {:error, :quote_expired}) do
    json_error(conn, 410, "Quote has expired", 10_030)
  end

  # --- 429 Too Many Requests ---

  def call(conn, {:error, :too_many_active_quotes}) do
    json_error(conn, 429, "Too many active quotes — settle or expire some first", 10_040)
  end

  # --- 503 Service Unavailable ---

  def call(conn, {:error, :insufficient_liquidity}) do
    json_error(conn, 503, "Insufficient liquidity for withdrawal", 20_001)
  end

  def call(conn, {:error, :payment_failed}) do
    json_error(conn, 503, "Lightning payment failed", 20_002)
  end

  def call(conn, {:error, :phoenixd_unreachable}) do
    json_error(conn, 503, "Lightning service unavailable", 20_003)
  end

  def call(conn, {:error, :too_many_concurrent}) do
    json_error(conn, 503, "Too many concurrent payments", 20_004)
  end

  def call(conn, {:error, :settlement_timeout}) do
    json_error(conn, 503, "Payment settlement pending — funds are held, check back shortly", 20_005)
  end

  def call(conn, {:error, :settlement_unknown}) do
    json_error(conn, 503, "Payment outcome unknown — funds are held pending operator reconciliation", 20_006)
  end

  def call(conn, {:error, :duplicate_bolt11}) do
    json_error(conn, 400, "A melt quote already exists for this invoice", 10_014)
  end

  # --- Catch-all: 500 ---

  def call(conn, {:error, _reason}) do
    json_error(conn, 500, "Internal server error", 0)
  end

  defp json_error(conn, status, detail, code) do
    conn
    |> put_status(status)
    |> put_resp_content_type("application/json")
    |> json(%{detail: detail, code: code})
  end

  # Escalation lives at the request boundary because this is the ONLY
  # layer with both the double-spend signal and the identifier the
  # rate limiter actually keys on (`circuit_id_hash`, set by the Gate
  # plug). The mint layer stays identity-free; the identity layer
  # never needs to reach into mint internals.
  defp escalate_double_spend(conn) do
    case conn.assigns[:circuit_id_hash] do
      hash when is_binary(hash) ->
        Minted.Identity.Escalation.record(hash)

      _absent ->
        :ok
    end
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end
end
