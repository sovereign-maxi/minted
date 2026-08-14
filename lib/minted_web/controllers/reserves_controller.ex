defmodule MintedWeb.ReservesController do
  @moduledoc """
  Proof of reserves endpoints.

  Returns the latest reserve proof and paginated history from the
  Reserves context (ProofGenerator).
  """

  use MintedWeb, :controller

  require Logger

  alias Minted.Reserves.Facade, as: ReservesFacade

  action_fallback MintedWeb.FallbackController

  @doc """
  GET /v1/reserves
  Returns the latest reserve proof including Nostr event reference.
  """
  def show(conn, _params) do
    proof = format_proof(ReservesFacade.latest_proof())

    conn
    |> put_status(200)
    |> json(Map.merge(proof, verifier_keys()))
  end

  @doc """
  GET /v1/reserves/history
  Returns paginated reserve proof history.
  """
  def history(conn, params) do
    limit = parse_limit(params)
    proofs = ReservesFacade.proof_history(limit)

    conn
    |> put_status(200)
    |> json(
      Map.merge(
        %{proofs: Enum.map(proofs, &format_proof/1), limit: limit, cursor: nil},
        verifier_keys()
      )
    )
  end

  # --- Private Helpers ---

  defp format_proof(nil) do
    %{
      ratio: 1.0,
      held: 0,
      outstanding: 0,
      proof: nil,
      attestation_count: 0,
      threshold_signature: nil,
      nostr_event_id: nil,
      timestamp: DateTime.to_iso8601(DateTime.utc_now())
    }
  end

  defp format_proof(%Vault.Proof{snapshot: snap} = proof) do
    %{
      ratio: format_ratio(snap.reserve_ratio),
      held: snap.total_held,
      outstanding: snap.outstanding,
      proof: safe_hex(proof.id),
      attestation_count: map_size(proof.attestations),
      threshold_signature: format_threshold_signature(proof),
      nostr_event_id: safe_hex(proof.publish_ref),
      timestamp: DateTime.to_iso8601(snap.captured_at)
    }
  end

  # Two pubkeys, two curves, two purposes. Calling them out
  # explicitly so a verifier never tries to validate the Ed25519
  # threshold_signature with the secp256k1 nostr pubkey.
  defp verifier_keys do
    %{
      verifier: %{
        nostr_publisher_pubkey: hex_or_nil(ReservesFacade.nostr_pubkey()),
        nostr_pubkey_curve: "secp256k1-bip340",
        guardian_signer_pubkey: hex_or_nil(ReservesFacade.guardian_pubkey()),
        guardian_pubkey_curve: "ed25519",
        threshold_signature_input: "Vault.Proof.canonical_bytes/1"
      }
    }
  end

  defp hex_or_nil({:ok, hex}), do: hex
  defp hex_or_nil({:error, _}), do: nil

  defp format_ratio(:infinity), do: 1.0
  defp format_ratio(ratio) when is_number(ratio), do: ratio

  defp format_threshold_signature(%{threshold_signature: nil}), do: nil

  defp format_threshold_signature(%{threshold_signature: sig}) do
    Base.encode16(sig, case: :lower)
  end

  defp safe_hex(nil), do: nil
  defp safe_hex(bin) when is_binary(bin), do: Base.encode16(bin, case: :lower)
  defp safe_hex(other), do: to_string(other)

  defp parse_limit(params) do
    case Map.get(params, "limit") do
      nil ->
        20

      val when is_binary(val) ->
        case Integer.parse(val) do
          {n, ""} -> min(max(n, 1), 100)
          _ -> 20
        end

      val when is_integer(val) ->
        min(max(val, 1), 100)

      _ ->
        20
    end
  end
end
