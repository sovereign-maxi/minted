defmodule Minted.Scenarios.WalletMeltReservationRollbackTest do
  @moduledoc """
  Pins the rollback contract for the multi-keyset reservation
  walker: when a later group fails, every previously-reserved group
  MUST be released. Previous behaviour left groups 1..N-1 reserved
  when group N failed; nothing swept them and
  `promote_pending_to_main` on the next restart durably marked them
  spent — the mint paid nothing yet the user's tokens were gone.
  """

  use ExUnit.Case, async: false

  @moduletag :scenario

  alias Minted.Mint.Facade, as: MintFacade
  alias Minted.Mint.Spent
  alias Minted.Mint.Token
  alias Minted.TestHelpers.WalletHelpers
  alias Minted.Wallet.Service

  setup do
    Minted.TestHelpers.StateHelpers.clean_state(%{})

    for {name, opts} <- [
          {Minted.Mint.Spent, [:set, :named_table, :public, read_concurrency: true]},
          {Minted.Mint.Spent.Y, [:set, :named_table, :public, read_concurrency: true]},
          {Minted.Mint.Spent.Pending, [:set, :named_table, :public, read_concurrency: true]}
        ] do
      if :ets.whereis(name) == :undefined, do: :ets.new(name, opts)
    end

    keyset = WalletHelpers.get_or_create_test_keyset()

    {:ok, keyset: keyset}
  end

  describe "verify_and_reserve_grouped/1 rollback" do
    test "rolls back all previously-reserved groups when a later group fails", %{keyset: keyset} do
      good_tokens = WalletHelpers.build_valid_tokens(keyset, [1, 2, 4])
      bad_tokens = build_invalid_tokens(1, keyset)

      # Baseline: the good group alone reserves cleanly.
      assert {:ok, _total} = MintFacade.verify_and_reserve(good_tokens, keyset)
      MintFacade.release_reservation(good_tokens, keyset)
      assert_none_pending(good_tokens)

      # Walker drives [good, bad]. Bad fails; good MUST be released,
      # not left orphaned in pending — otherwise the next restart
      # would promote_pending_to_main and permanently spend it.
      grouped = [{keyset, good_tokens}, {keyset, bad_tokens}]

      result = Service.__verify_and_reserve_grouped__(grouped)
      assert match?({:error, _}, result) or match?({:error, _, _}, result)

      assert_none_pending(good_tokens)
    end

    test "walker returns :ok when every group verifies", %{keyset: keyset} do
      good_a = WalletHelpers.build_valid_tokens(keyset, [1, 2])
      good_b = WalletHelpers.build_valid_tokens(keyset, [4, 8])

      grouped = [{keyset, good_a}, {keyset, good_b}]

      assert :ok = Service.__verify_and_reserve_grouped__(grouped)

      MintFacade.release_reservation(good_a, keyset)
      MintFacade.release_reservation(good_b, keyset)
    end
  end

  # Malformed C bytes — cashew's verify rejects, so the executor's
  # verify_and_reserve returns an error and the group's tokens
  # never make it into the pending table.
  defp build_invalid_tokens(count, keyset) do
    for _ <- 1..count do
      %Token{
        amount: 1,
        secret: :crypto.strong_rand_bytes(32),
        c: :crypto.strong_rand_bytes(33),
        keyset_id: keyset.id
      }
    end
  end

  defp assert_none_pending(tokens) do
    hashes = Enum.map(tokens, fn t -> :crypto.hash(:sha256, t.secret) end)

    for hash <- hashes do
      refute :ets.member(Spent.Pending, hash)
    end
  end
end
