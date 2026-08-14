defmodule Minted.Scenarios.SecurityHardeningTest do
  @moduledoc """
  Cross-domain scenario tests for security hardening:
  batch size limits, keyset ID validation, double-spend escalation,
  and token deserialization payload limits.
  """

  use ExUnit.Case, async: false

  @moduletag :scenario

  import Minted.TestHelpers.StateHelpers
  import Minted.TestHelpers.WalletHelpers

  alias Minted.Identity.Escalation
  alias Minted.Mint.Keyset
  alias Minted.Mint.Services.Signing
  alias Minted.Mint.Signatures.Message
  alias Minted.Mint.Token

  setup :clean_state

  setup do
    keyset = get_or_create_test_keyset()
    {:ok, keyset: keyset}
  end

  describe "batch size limit" do
    test "batch > 1000 blinded messages rejected by Signing", %{keyset: keyset} do
      # Build 1001 blinded messages
      messages =
        for _i <- 1..1001 do
          secret = :crypto.strong_rand_bytes(32)
          {:ok, {b_prime, _r}} = Cashew.step1_alice(secret)
          %Message{amount: 1, b_prime: b_prime}
        end

      assert {:error, :batch_too_large} = Signing.sign(messages, keyset)
    end

    test "boundary: 1001 rejected, 1000 not rejected by batch guard", %{keyset: keyset} do
      # Build minimal messages (only need count, not valid crypto)
      make_msg = fn ->
        secret = :crypto.strong_rand_bytes(32)
        {:ok, {b_prime, _r}} = Cashew.step1_alice(secret)
        %Message{amount: 1, b_prime: b_prime}
      end

      # 1001 is rejected by the > 1000 guard
      messages_1001 = for _i <- 1..1001, do: make_msg.()
      assert {:error, :batch_too_large} = Signing.sign(messages_1001, keyset)

      # 1000 is NOT rejected by the batch-size guard. Prove the
      # boundary by verifying an EXPIRED keyset (no live keys) hits
      # the next guard (:keyset_expired) instead of :batch_too_large.
      # Retired keysets are legitimately signable so they can't stand
      # in as a "next-guard" sentinel here.
      {:ok, retired} = Keyset.retire(keyset)
      {:ok, expired_keyset} = Keyset.expire(retired)
      messages_1000 = Enum.take(messages_1001, 1000)
      assert {:error, :keyset_expired} = Signing.sign(messages_1000, expired_keyset)
    end
  end

  describe "invalid keyset ID formats" do
    test "uppercase hex rejected during deserialization" do
      payload =
        build_cashu_payload([
          %{"amount" => 1, "secret" => hex_secret(), "C" => hex_c(), "id" => "AABBCCDD"}
        ])

      assert {:error, :invalid_proof_encoding} = Token.deserialize(payload)
    end

    test "mixed case hex rejected during deserialization" do
      payload =
        build_cashu_payload([
          %{"amount" => 1, "secret" => hex_secret(), "C" => hex_c(), "id" => "aAbBcCdD"}
        ])

      assert {:error, :invalid_proof_encoding} = Token.deserialize(payload)
    end

    test "keyset ID too long (> 16 chars) rejected" do
      long_id = String.duplicate("ab", 9)
      assert byte_size(long_id) == 18

      payload =
        build_cashu_payload([
          %{"amount" => 1, "secret" => hex_secret(), "C" => hex_c(), "id" => long_id}
        ])

      assert {:error, :invalid_proof_encoding} = Token.deserialize(payload)
    end

    test "non-hex characters rejected" do
      payload =
        build_cashu_payload([
          %{"amount" => 1, "secret" => hex_secret(), "C" => hex_c(), "id" => "zz00gg11"}
        ])

      assert {:error, :invalid_proof_encoding} = Token.deserialize(payload)
    end

    test "empty keyset ID rejected" do
      payload =
        build_cashu_payload([
          %{"amount" => 1, "secret" => hex_secret(), "C" => hex_c(), "id" => ""}
        ])

      assert {:error, :invalid_proof_encoding} = Token.deserialize(payload)
    end
  end

  describe "double-spend escalation" do
    test "repeated attempts increase cooldown multiplier" do
      circuit = :crypto.strong_rand_bytes(32)

      # First attempt: 3x multiplier (3^1)
      :ok = Escalation.record(circuit)
      assert {:escalated, 3} = Escalation.status(circuit)

      # Second attempt: 9x multiplier (3^2)
      :ok = Escalation.record(circuit)
      assert {:escalated, 9} = Escalation.status(circuit)

      # Third attempt: 27x multiplier (3^3)
      :ok = Escalation.record(circuit)
      assert {:escalated, 27} = Escalation.status(circuit)

      # Fourth attempt: 81x multiplier (3^4, capped at max)
      :ok = Escalation.record(circuit)
      assert {:escalated, 81} = Escalation.status(circuit)

      # Fifth attempt: still capped at 81
      :ok = Escalation.record(circuit)
      assert {:escalated, 81} = Escalation.status(circuit)

      on_exit(fn ->
        Escalation.reset(circuit)
      end)
    end

    test "banned? returns true at max multiplier" do
      circuit = :crypto.strong_rand_bytes(32)

      refute Escalation.banned?(circuit)

      # Escalate to max
      for _i <- 1..4, do: Escalation.record(circuit)

      assert Escalation.banned?(circuit)

      on_exit(fn ->
        Escalation.reset(circuit)
      end)
    end

    test "reset clears escalation state" do
      circuit = :crypto.strong_rand_bytes(32)

      Escalation.record(circuit)
      assert {:escalated, _} = Escalation.status(circuit)

      Escalation.reset(circuit)
      assert :ok = Escalation.status(circuit)
    end
  end

  describe "token deserialization rejects oversized payloads" do
    test "payload exceeding 10MB is rejected" do
      # Build a base64 payload > 10MB
      large_base64 = String.duplicate("A", 10_000_001)
      assert {:error, :backup_too_large} = Token.deserialize("cashuA" <> large_base64)
    end

    test "too many tokens (> 10_000) in payload rejected" do
      # Build a payload with 10_001 proof entries
      proofs =
        for _i <- 1..10_001 do
          %{
            "amount" => 1,
            "secret" => hex_secret(),
            "C" => hex_c(),
            "id" => "aabbccdd"
          }
        end

      json = Jason.encode!(%{"token" => [%{"proofs" => proofs}]})
      encoded = Base.url_encode64(json, padding: false)

      # This should be rejected either by size limit or token count limit
      result = Token.deserialize("cashuA" <> encoded)
      assert {:error, reason} = result
      assert reason in [:too_many_tokens, :backup_too_large]
    end

    test "invalid base64 rejected" do
      assert {:error, :invalid_encoding} = Token.deserialize("cashuA" <> "not-valid-base64!!!")
    end

    test "non-cashuA prefix rejected" do
      assert {:error, :invalid_format} = Token.deserialize("cashuB" <> "anything")
    end
  end

  # --- Helpers ---

  defp hex_secret do
    :crypto.strong_rand_bytes(32) |> Base.encode16(case: :lower)
  end

  defp hex_c do
    # 33-byte compressed point (prefix 0x02 + 32 bytes)
    (<<0x02>> <> :crypto.strong_rand_bytes(32)) |> Base.encode16(case: :lower)
  end

  defp build_cashu_payload(proofs) do
    json = Jason.encode!(%{"token" => [%{"proofs" => proofs}]})
    "cashuA" <> Base.url_encode64(json, padding: false)
  end
end
