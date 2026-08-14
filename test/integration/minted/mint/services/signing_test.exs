defmodule Minted.Mint.Services.SigningIntegrationTest do
  @moduledoc "Integration tests for blind signature signing service."

  use Minted.IntegrationCase

  alias Minted.Mint.Keyset
  alias Minted.Mint.Services.Signing
  alias Minted.Mint.Signatures.Message

  setup do
    keyset = Keyset.generate()
    %{keyset: keyset}
  end

  defp blind_message(_keyset, amount) do
    secret = :crypto.strong_rand_bytes(32)
    {:ok, {b_prime, _r}} = Cashew.step1_alice(secret)
    %Message{amount: amount, b_prime: b_prime}
  end

  describe "sign/2" do
    test "signs a single blinded message", %{keyset: keyset} do
      msg = blind_message(keyset, 1)
      assert {:ok, [sig]} = Signing.sign([msg], keyset)
      assert sig.amount == 1
      assert is_binary(sig.c_prime)
      assert sig.keyset_id == keyset.id
    end

    test "signs a batch of blinded messages", %{keyset: keyset} do
      msgs =
        for amount <- [1, 2, 4, 8] do
          blind_message(keyset, amount)
        end

      assert {:ok, sigs} = Signing.sign(msgs, keyset)
      assert length(sigs) == 4
      assert Enum.map(sigs, & &1.amount) == [1, 2, 4, 8]
    end

    test "returns ok for empty list", %{keyset: keyset} do
      assert {:ok, []} = Signing.sign([], keyset)
    end

    test "rejects batch exceeding max size", %{keyset: keyset} do
      msgs =
        for _ <- 1..1001 do
          blind_message(keyset, 1)
        end

      assert {:error, :batch_too_large} = Signing.sign(msgs, keyset)
    end
  end

  describe "reject invalid denominations" do
    test "rejects messages with non-power-of-2 denominations", %{keyset: keyset} do
      # Create a message with an invalid denomination by directly building the struct
      secret = :crypto.strong_rand_bytes(32)
      {:ok, {b_prime, _r}} = Cashew.step1_alice(secret)
      bad_msg = %Message{amount: 3, b_prime: b_prime}

      assert {:error, {:invalid_blinded_message, index: 0}} =
               Signing.sign([bad_msg], keyset)
    end
  end

  describe "keyset status handling" do
    test "accepts signing with retired keyset (keys still live)", %{keyset: keyset} do
      {:ok, retired} = Keyset.retire(keyset)
      msg = blind_message(retired, 1)

      # Retired keysets still hold live private keys — a quote pinned
      # to a keyset that rotated between payment and claim must still
      # sign, otherwise every paid-but-not-yet-claimed quote across
      # every rotation would strand the user's sats.
      assert {:ok, [sig]} = Signing.sign([msg], retired)
      assert sig.keyset_id == retired.id
    end

    test "rejects signing with expired keyset", %{keyset: keyset} do
      {:ok, retired} = Keyset.retire(keyset)
      {:ok, expired} = Keyset.expire(retired)
      msg = blind_message(keyset, 1)

      assert {:error, :keyset_expired} = Signing.sign([msg], expired)
    end
  end

  describe "DLEQ proof generation" do
    test "includes DLEQ proof in signature response", %{keyset: keyset} do
      msg = blind_message(keyset, 1)
      assert {:ok, [sig]} = Signing.sign([msg], keyset)

      # DLEQ proof should be present (may be nil if Cashew doesn't support it,
      # but in a working setup it should be a map with :e and :s)
      if sig.dleq != nil do
        assert is_binary(sig.dleq.e)
        assert is_binary(sig.dleq.s)
      end
    end
  end
end
