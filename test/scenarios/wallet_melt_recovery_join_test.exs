defmodule Minted.Scenarios.WalletMeltRecoveryJoinTest do
  @moduledoc """
  Wallet-initiated melts have no `quote_id` (they mint no Cashu quote;
  they spend directly on Lightning). Recovery MUST NOT collapse them
  all to a single nil-keyed slot in the incomplete-melt map, or one
  wallet melt's settlement will discard every concurrent melt's
  blocked-hash payload — turning a partial-crash recovery from
  correct into a double-spend surface.

  Pins the join contract: `melt_id` is the fallback join key when
  `quote_id` is absent.
  """

  use ExUnit.Case, async: false

  @moduletag :scenario

  alias Minted.Storage.Recovery

  describe "wallet melt started/settled join" do
    test "two concurrent wallet melts retain independent slots through started+settled" do
      wallet_melt_a = wallet_melt_payload("melt-a", ["hash-a-1", "hash-a-2"])
      wallet_melt_b = wallet_melt_payload("melt-b", ["hash-b-1", "hash-b-2"])

      {:ok, melts, _} =
        Recovery.__dispatch_melt_replay__(:melt_started, wallet_melt_a, %{}, %{})

      {:ok, melts, _} =
        Recovery.__dispatch_melt_replay__(:melt_started, wallet_melt_b, melts, %{})

      assert map_size(melts) == 2, "both concurrent wallet melts must be tracked"
      assert Map.has_key?(melts, "melt-a")
      assert Map.has_key?(melts, "melt-b")

      # Settle A only. B's entry MUST survive.
      {:ok, melts, _} =
        Recovery.__dispatch_melt_replay__(
          :melt_settled,
          %{melt_id: "melt-a", payment_id: "pid-a"},
          melts,
          %{}
        )

      assert Map.has_key?(melts, "melt-b"),
             "B's incomplete-melt entry must survive A's settlement"

      refute Map.has_key?(melts, "melt-a"), "A's entry is cleared once settled"
    end

    test "commit_failed settle keeps entry for the correct melt only" do
      wallet_melt_a = wallet_melt_payload("melt-a", ["hash-a-1"])
      wallet_melt_b = wallet_melt_payload("melt-b", ["hash-b-1"])

      {:ok, melts, _} =
        Recovery.__dispatch_melt_replay__(:melt_started, wallet_melt_a, %{}, %{})

      {:ok, melts, _} =
        Recovery.__dispatch_melt_replay__(:melt_started, wallet_melt_b, melts, %{})

      # A settles with commit_failed=true — the settlement is a signal to
      # BLOCK A's hashes on next boot, but must leave B untouched.
      {:ok, melts_after, _} =
        Recovery.__dispatch_melt_replay__(
          :melt_settled,
          %{melt_id: "melt-a", payment_id: "pid-a", commit_failed: true},
          melts,
          %{}
        )

      assert Map.has_key?(melts_after, "melt-a"),
             "commit_failed keeps A's payload in incomplete set for blocked-hash rebuild"

      assert Map.has_key?(melts_after, "melt-b"),
             "B's slot must be untouched by A's commit_failed settlement"
    end

    test "API melts with quote_id and wallet melts with only melt_id coexist" do
      api_melt = %{quote_id: "quote-1", amount: 500, melt_id: nil, secret_hashes: []}
      wallet_melt = wallet_melt_payload("melt-x", ["hash-x-1"])

      {:ok, melts, _} =
        Recovery.__dispatch_melt_replay__(:melt_started, api_melt, %{}, %{})

      {:ok, melts, _} =
        Recovery.__dispatch_melt_replay__(:melt_started, wallet_melt, melts, %{})

      assert Map.has_key?(melts, "quote-1")
      assert Map.has_key?(melts, "melt-x")
      assert map_size(melts) == 2
    end

    test "settlement matches the same fallback key started used" do
      # Started under melt_id (no quote_id). Settlement carries the same
      # melt_id. Fallback logic must derive the same key from both.
      started = wallet_melt_payload("melt-z", ["hash-z-1"])
      settled = %{melt_id: "melt-z", payment_id: "pid-z"}

      {:ok, melts, _} =
        Recovery.__dispatch_melt_replay__(:melt_started, started, %{}, %{})

      assert Map.has_key?(melts, "melt-z")

      {:ok, melts_after, _} =
        Recovery.__dispatch_melt_replay__(:melt_settled, settled, melts, %{})

      assert melts_after == %{}, "settlement must clear the started entry by matching melt_id"
    end
  end

  defp wallet_melt_payload(melt_id, secret_hashes) do
    %{
      melt_id: melt_id,
      payment_id: "pid-#{melt_id}",
      bolt11: "lnbc_test_#{melt_id}",
      amount: 500,
      token_count: length(secret_hashes),
      secret_hashes: secret_hashes,
      keyset_ids: ["ks-test"]
    }
  end
end
