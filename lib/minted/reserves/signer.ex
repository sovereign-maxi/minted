defmodule Minted.Reserves.Signer do
  @moduledoc """
  Ed25519 signer for reserve proofs.

  Each node signs the canonical proof bytes independently with its
  local Ed25519 key. Attestation collection (performed by
  `Vault.Generator` before this signer runs) provides multi-party
  validation: each peer node signs the snapshot after verifying it
  matches their local state. A proof with >= t attestations is
  cryptographic proof of multi-party agreement.

  The `threshold_signature` field is the issuing node's Ed25519
  signature over the canonical proof bytes (including all collected
  attestations) — it commits the node to the assembled proof.
  It is NOT a threshold signature in the cryptographic sense; the
  threshold validation is provided by the attestations.

  Passed to `Vault.Generator` as the `:signer` option in
  `Minted.Reserves.Supervisor`.
  """

  require Logger

  @doc """
  Signs a reserve proof with the node's local Ed25519 key.

  Returns `{:ok, signature}` or `{:error, reason}`.
  """
  @spec sign(Vault.Proof.t(), {binary(), binary(), binary()}) ::
          {:ok, binary()} | {:error, term()}
  def sign(%Vault.Proof{} = proof, {_node_id, privkey, _pubkey}) do
    # Each node signs its own proof independently. The attestation-collection
    # mechanism provides multi-party validation.
    canonical = Vault.Proof.canonical_bytes(proof)
    signature = :crypto.sign(:eddsa, :none, canonical, [privkey, :ed25519])
    Logger.info("Signer: reserve proof signed")
    {:ok, signature}
  rescue
    e ->
      Logger.error("Signer: reserve proof signing failed: #{Exception.message(e)}")
      {:error, :signing_exception}
  catch
    :exit, reason ->
      Logger.error("Signer: signing process exited: #{inspect(reason)}")
      {:error, :signing_unavailable}
  end
end
