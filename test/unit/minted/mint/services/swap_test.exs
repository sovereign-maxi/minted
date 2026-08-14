defmodule Minted.Mint.Services.SwapTest do
  @moduledoc """
  Unit tests for Swap pure logic.

  Tests amount-mismatch detection and empty-swap guards.
  Integration tests (with ETS/GenServer state) live in
  test/integration/minted/mint/swap_test.exs.
  """

  use ExUnit.Case, async: true

  alias Minted.Mint.Services.Swap

  # Minimal structs for testing pure swap logic.
  defp token(amount),
    do: %Minted.Mint.Token{amount: amount, secret: "s", c: <<0::264>>, keyset_id: "00deadbeef"}

  defp blinded_msg(amount),
    do: %Minted.Mint.Signatures.Message{amount: amount, b_prime: :crypto.strong_rand_bytes(33)}

  # -- empty-swap guard --

  describe "empty swap guards" do
    test "rejects empty old tokens" do
      assert {:error, :empty_swap} = Swap.swap([], [blinded_msg(1)], keyset())
    end

    test "rejects empty new messages" do
      assert {:error, :empty_swap} = Swap.swap([token(1)], [], keyset())
    end

    test "rejects both empty" do
      assert {:error, :empty_swap} = Swap.swap([], [], keyset())
    end
  end

  # -- amount mismatch --

  describe "amount mismatch detection" do
    test "rejects when output > input" do
      old = [token(1)]
      new = [blinded_msg(2)]

      assert {:error, {:amount_mismatch, 1, 2}} = Swap.swap(old, new, keyset())
    end

    test "rejects when input > output" do
      old = [token(4), token(8)]
      new = [blinded_msg(2)]

      assert {:error, {:amount_mismatch, 12, 2}} = Swap.swap(old, new, keyset())
    end

    test "rejects split with mismatch" do
      old = [token(8)]
      new = [blinded_msg(4), blinded_msg(2)]

      assert {:error, {:amount_mismatch, 8, 6}} = Swap.swap(old, new, keyset())
    end
  end

  # Dummy keyset — only needed for the struct match; amount-mismatch and empty
  # guards fire before any keyset interaction.
  defp keyset do
    %Minted.Mint.Keyset{
      id: "00deadbeef",
      unit: "sat",
      status: :active,
      keys: %{},
      created_at: DateTime.utc_now()
    }
  end
end
