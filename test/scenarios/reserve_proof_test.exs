defmodule Minted.Scenarios.ReserveProofTest do
  @moduledoc """
  Scenario tests for reserve proof generation.
  Verifies that proofs are generated and persisted.
  """

  use ExUnit.Case, async: false

  @moduletag :scenario

  import Minted.TestHelpers.ProcessHelpers
  import Minted.TestHelpers.StateHelpers

  setup :clean_state

  describe "proof generation cycle" do
    test "generates proof with at least self-attestation" do
      # The live Vault.Generator should be running from app startup.
      # Trigger a proof cycle and verify the result.
      Vault.Generator.generate_now()
      await_condition(fn -> Vault.Generator.latest() != nil end)

      proof = Vault.Generator.latest()
      assert proof != nil
      assert proof.status in [:published, :signing]
      assert proof.snapshot.total_held >= 0
      assert proof.snapshot.outstanding >= 0
      assert map_size(proof.attestations) >= 1
    end

    test "proof count increments over multiple cycles" do
      initial_count = length(Vault.Generator.history(100))

      Vault.Generator.generate_now()
      await_condition(fn -> length(Vault.Generator.history(100)) > initial_count end)

      new_count = length(Vault.Generator.history(100))
      assert new_count > initial_count
    end

    test "proof has valid snapshot fields" do
      Vault.Generator.generate_now()
      await_condition(fn -> Vault.Generator.latest() != nil end)

      proof = Vault.Generator.latest()
      snapshot = proof.snapshot

      assert is_integer(snapshot.total_held)
      assert is_integer(snapshot.outstanding)
      assert snapshot.total_held >= 0
      assert snapshot.outstanding >= 0
      assert %DateTime{} = snapshot.captured_at
    end

    test "proof has threshold signature" do
      Vault.Generator.generate_now()
      await_condition(fn -> Vault.Generator.latest() != nil end)

      proof = Vault.Generator.latest()
      assert is_binary(proof.threshold_signature)
      assert byte_size(proof.threshold_signature) == 64
    end
  end
end
