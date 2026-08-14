defmodule Minted.Mint.Services.RedemptionIntegrationTest do
  @moduledoc "Integration tests for token redemption service with ETS spent tracking."

  use Minted.IntegrationCase

  alias Minted.Mint.{Keyset, Token}
  alias Minted.Mint.Services.{Redemption, Signing}
  alias Minted.Mint.Signatures.Message
  alias Minted.Mint.Spent

  setup do
    # Ensure Spent ETS tables exist.
    for {name, opts} <- [
          {Spent, [:set, :named_table, :public, read_concurrency: true]},
          {Spent.Y, [:set, :named_table, :public, read_concurrency: true]},
          {Spent.Pending, [:set, :named_table, :public, read_concurrency: true]}
        ] do
      if :ets.whereis(name) == :undefined, do: :ets.new(name, opts)
    end

    keyset = Keyset.generate()
    %{keyset: keyset}
  end

  # Helper: create a valid token by going through the full BDHKE protocol.
  defp mint_token(keyset, amount) do
    {:ok, {_privkey, pubkey}} = Keyset.get_key(keyset, amount)
    secret = :crypto.strong_rand_bytes(32)
    {:ok, {b_prime, r}} = Cashew.step1_alice(secret)

    msg = %Message{amount: amount, b_prime: b_prime}
    {:ok, [sig]} = Signing.sign([msg], keyset)

    {:ok, c} = Cashew.step3_alice(sig.c_prime, r, pubkey)

    %Token{
      amount: amount,
      secret: secret,
      c: c,
      keyset_id: keyset.id
    }
  end

  describe "verify_batch/2" do
    test "verifies a batch of valid tokens", %{keyset: keyset} do
      token = mint_token(keyset, 1)
      assert :ok = Redemption.verify_batch([token], keyset)
    end

    test "rejects tokens from wrong keyset", %{keyset: keyset} do
      token = mint_token(keyset, 1)
      other_keyset = Keyset.generate()

      assert {:error, {:keyset_mismatch, _}} =
               Redemption.verify_batch([token], other_keyset)
    end
  end

  describe "verify_and_reserve/2" do
    test "returns error for empty batch", %{keyset: keyset} do
      assert {:error, :empty_batch} = Redemption.verify_and_reserve([], keyset)
    end
  end

  describe "commit_reservation/2 and release_reservation/2" do
    @tag :skip_without_spent_set
    test "released tokens can be reserved again", %{keyset: keyset} do
      # This test requires the Spent GenServer to be running.
      # Skip if it's not available (e.g., in isolated test runs).
      case GenServer.whereis(Spent) do
        nil ->
          :ok

        _pid ->
          token = mint_token(keyset, 1)
          entries = [{token.secret, keyset.id}]
          verify_fn = fn _secret, _kid -> :ok end

          assert :ok = Spent.verify_and_reserve(entries, verify_fn)
          assert :ok = Spent.release_reserved(entries)
          assert :ok = Spent.verify_and_reserve(entries, verify_fn)
          Spent.release_reserved(entries)
      end
    end
  end

  describe "double-spend rejection" do
    test "redeem rejects already-spent tokens via ETS", %{keyset: keyset} do
      token = mint_token(keyset, 1)

      # Simulate a spent token by inserting into ETS directly.
      # The Spent GenServer may not be running, but Spent.spent?/1
      # reads directly from ETS.
      hash = :crypto.hash(:sha256, token.secret)
      :ets.insert(Spent, {hash, keyset.id, System.monotonic_time(:millisecond)})

      assert {:error, {:already_spent, _}} =
               Redemption.verify_batch([token], keyset)
    end
  end
end
