# Unit test
defmodule Minted.Storage.RecoveryTest do
  @moduledoc "Unit tests for Minted.Storage.Recovery pure decision functions."

  use ExUnit.Case, async: true

  alias Locker.WAL.Entry
  alias Minted.Storage.Recovery

  describe "spent_guard_verdict/2" do
    test "missing backend with redemption history is an error" do
      entries = [%Entry{type: :tokens_burned, payload: %{amount: 100}}]
      assert {:error, :spent_set_missing} = Recovery.spent_guard_verdict(entries, true)
    end

    test "missing backend with melt history is an error" do
      entries = [%Entry{type: :melt_started, payload: %{}}]
      assert {:error, :spent_set_missing} = Recovery.spent_guard_verdict(entries, true)
    end

    test "missing backend with swap history is an error" do
      entries = [%Entry{type: :swap_started, payload: %{}}]
      assert {:error, :spent_set_missing} = Recovery.spent_guard_verdict(entries, true)
    end

    test "missing backend with only benign history boots" do
      entries = [
        %Entry{type: :tokens_minted, payload: %{amount: 100}},
        %Entry{type: :keyset_created, payload: %{}}
      ]

      assert :ok = Recovery.spent_guard_verdict(entries, true)
    end

    test "missing backend with no history boots (fresh install)" do
      assert :ok = Recovery.spent_guard_verdict([], true)
    end

    test "present backend with redemption history boots" do
      entries = [%Entry{type: :swap_settled, payload: %{}}]
      assert :ok = Recovery.spent_guard_verdict(entries, false)
    end
  end

  describe "swap join keys" do
    test "concurrent swaps with distinct swap_ids do not collapse" do
      {:ok, _m, swaps} =
        Recovery.__dispatch_melt_replay__(
          :swap_started,
          %{swap_id: "aaa", amount: 100, secret_hashes: ["h1"]},
          %{},
          %{}
        )

      {:ok, _m2, swaps2} =
        Recovery.__dispatch_melt_replay__(
          :swap_started,
          %{swap_id: "bbb", amount: 200, secret_hashes: ["h2"]},
          %{},
          swaps
        )

      assert map_size(swaps2) == 2

      {:ok, _m3, swaps3} =
        Recovery.__dispatch_melt_replay__(
          :swap_settled,
          %{swap_id: "aaa"},
          %{},
          swaps2
        )

      assert map_size(swaps3) == 1
      assert Map.has_key?(swaps3, "bbb")
    end

    test "legacy entries without swap_id fall back to quote_id then :unknown" do
      {:ok, _m, swaps} =
        Recovery.__dispatch_melt_replay__(
          :swap_started,
          %{quote_id: "q1", amount: 100},
          %{},
          %{}
        )

      assert Map.has_key?(swaps, "q1")

      {:ok, _m2, swaps2} =
        Recovery.__dispatch_melt_replay__(:swap_started, %{amount: 50}, %{}, swaps)

      assert Map.has_key?(swaps2, :unknown)
    end
  end

  describe "proof_spent replay" do
    test "queues the secret hash into the blocked set instead of touching Spent" do
      secret = :crypto.strong_rand_bytes(32)

      assert {:ok, _melts, _swaps, [{hash, "ks1"}]} =
               Recovery.__replay_entry__(
                 %{type: :proof_spent, payload: %{secret: secret, keyset_id: "ks1"}},
                 %{},
                 %{},
                 []
               )

      assert hash == :crypto.hash(:sha256, secret)
    end

    test "a malformed proof_spent entry is a replay failure, not a silent skip" do
      assert {:error, _} =
               Recovery.__replay_entry__(
                 %{type: :proof_spent, payload: %{secret: 12_345}},
                 %{},
                 %{},
                 []
               )
    end
  end
end
