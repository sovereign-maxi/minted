defmodule Minted.Mint.SpentIntegrationTest do
  @moduledoc "Integration tests for spent token ETS tracking and double-spend detection."

  use Minted.IntegrationCase

  import Minted.TestHelpers.ProcessHelpers

  alias Minted.Mint.Keyset
  alias Minted.Mint.Spent
  alias Minted.Storage.Facade, as: StorageFacade

  setup do
    # Ensure ETS tables exist (normally created by Holder).
    for {name, opts} <- [
          {Minted.Mint.Spent, [:set, :named_table, :public, read_concurrency: true]},
          {Minted.Mint.Spent.Y, [:set, :named_table, :public, read_concurrency: true]},
          {Minted.Mint.Spent.Pending, [:set, :named_table, :public, read_concurrency: true]}
        ] do
      if :ets.whereis(name) == :undefined, do: :ets.new(name, opts)
    end

    # Start Spent if not already running.
    case GenServer.whereis(Spent) do
      nil ->
        {:ok, pid} = Spent.start_link()
        on_exit(fn -> safe_stop(pid) end)
        :ok

      _pid ->
        Spent.clear()
        :ok
    end
  end

  defp unique_secret do
    "secret_#{:erlang.unique_integer([:positive, :monotonic])}"
  end

  defp unique_keyset_id do
    "keyset_#{:erlang.unique_integer([:positive, :monotonic])}"
  end

  describe "mark_spent/2 and spent?/1" do
    test "marks a token as spent and detects it" do
      secret = unique_secret()
      keyset_id = unique_keyset_id()

      refute Spent.spent?(secret)
      assert :ok = Spent.mark_spent(secret, keyset_id)
      assert Spent.spent?(secret)
    end

    test "rejects double-spend of the same secret" do
      secret = unique_secret()
      keyset_id = unique_keyset_id()

      assert :ok = Spent.mark_spent(secret, keyset_id)
      assert {:error, :already_spent} = Spent.mark_spent(secret, keyset_id)
    end

    test "different secrets are independent" do
      s1 = unique_secret()
      s2 = unique_secret()
      keyset_id = unique_keyset_id()

      assert :ok = Spent.mark_spent(s1, keyset_id)
      assert Spent.spent?(s1)
      refute Spent.spent?(s2)
    end
  end

  describe "mark_spent_batch/1" do
    test "marks multiple tokens in a single batch" do
      keyset_id = unique_keyset_id()
      secrets = for _ <- 1..5, do: unique_secret()
      entries = Enum.map(secrets, &{&1, keyset_id})

      assert :ok = Spent.mark_spent_batch(entries)

      Enum.each(secrets, fn secret ->
        assert Spent.spent?(secret), "Expected #{secret} to be spent"
      end)
    end

    test "rejects batch with intra-batch duplicate secrets" do
      secret = unique_secret()
      keyset_id = unique_keyset_id()
      entries = [{secret, keyset_id}, {secret, keyset_id}]

      assert {:error, :double_spend} = Spent.mark_spent_batch(entries)
    end

    test "rejects batch when one secret is already spent" do
      keyset_id = unique_keyset_id()
      s1 = unique_secret()
      s2 = unique_secret()

      assert :ok = Spent.mark_spent(s1, keyset_id)

      entries = [{s1, keyset_id}, {s2, keyset_id}]
      assert {:error, :double_spend} = Spent.mark_spent_batch(entries)

      # s2 should not have been marked (atomic rollback)
      refute Spent.spent?(s2)
    end
  end

  describe "verify_and_mark_spent/2" do
    test "verifies then marks when verification passes" do
      keyset_id = unique_keyset_id()
      secrets = for _ <- 1..3, do: unique_secret()
      entries = Enum.map(secrets, &{&1, keyset_id})

      verify_fn = fn _secret, _kid -> :ok end

      assert :ok = Spent.verify_and_mark_spent(entries, verify_fn)

      Enum.each(secrets, fn secret ->
        assert Spent.spent?(secret)
      end)
    end

    test "rejects batch when verification fails for any entry" do
      keyset_id = unique_keyset_id()
      good_secret = unique_secret()
      bad_secret = unique_secret()
      entries = [{good_secret, keyset_id}, {bad_secret, keyset_id}]

      verify_fn = fn secret, _kid ->
        if secret == bad_secret, do: {:error, :invalid_signature}, else: :ok
      end

      assert {:error, :invalid_signature} =
               Spent.verify_and_mark_spent(entries, verify_fn)

      # Neither should be marked since verification failed
      refute Spent.spent?(good_secret)
      refute Spent.spent?(bad_secret)
    end

    test "rejects double-spend even when verification passes" do
      keyset_id = unique_keyset_id()
      secret = unique_secret()

      assert :ok = Spent.mark_spent(secret, keyset_id)

      new_secret = unique_secret()
      entries = [{secret, keyset_id}, {new_secret, keyset_id}]
      verify_fn = fn _secret, _kid -> :ok end

      assert {:error, :double_spend} =
               Spent.verify_and_mark_spent(entries, verify_fn)
    end

    test "passes 3-arity error tuples through from verify_fn" do
      keyset_id = unique_keyset_id()
      secret = unique_secret()
      entries = [{secret, keyset_id}]

      verify_fn = fn _secret, _kid -> {:error, :bad_sig, %{detail: "test"}} end

      assert {:error, :bad_sig, %{detail: "test"}} =
               Spent.verify_and_mark_spent(entries, verify_fn)
    end
  end

  describe "verify_and_reserve / commit_reserved / release_reserved" do
    test "reserve then commit marks tokens as spent" do
      keyset_id = unique_keyset_id()
      secrets = for _ <- 1..3, do: unique_secret()
      entries = Enum.map(secrets, &{&1, keyset_id})
      verify_fn = fn _secret, _kid -> :ok end

      assert :ok = Spent.verify_and_reserve(entries, verify_fn)

      # Reserved tokens should appear as spent (blocks double-spend)
      Enum.each(secrets, fn secret ->
        assert Spent.spent?(secret), "Reserved secret should appear as spent"
      end)

      # Commit promotes them to durable storage
      assert :ok = Spent.commit_reserved(entries)

      Enum.each(secrets, fn secret ->
        assert Spent.spent?(secret), "Committed secret should still be spent"
      end)
    end

    test "reserve then release makes tokens available again" do
      keyset_id = unique_keyset_id()
      secret = unique_secret()
      entries = [{secret, keyset_id}]
      verify_fn = fn _secret, _kid -> :ok end

      assert :ok = Spent.verify_and_reserve(entries, verify_fn)
      assert Spent.spent?(secret)

      assert :ok = Spent.release_reserved(entries)
      refute Spent.spent?(secret)
    end

    test "reserve rejects already-spent tokens" do
      keyset_id = unique_keyset_id()
      secret = unique_secret()

      assert :ok = Spent.mark_spent(secret, keyset_id)

      entries = [{secret, keyset_id}]
      verify_fn = fn _secret, _kid -> :ok end

      assert {:error, :double_spend} =
               Spent.verify_and_reserve(entries, verify_fn)
    end

    test "reserve rejects intra-batch duplicates" do
      keyset_id = unique_keyset_id()
      secret = unique_secret()
      entries = [{secret, keyset_id}, {secret, keyset_id}]
      verify_fn = fn _secret, _kid -> :ok end

      assert {:error, :double_spend} =
               Spent.verify_and_reserve(entries, verify_fn)
    end
  end

  describe "compact_keyset/1" do
    test "removes entries belonging to a specific (expired) keyset" do
      kid_a = install_expired_keyset()
      kid_b = install_expired_keyset()

      secrets_a = for _ <- 1..3, do: unique_secret()
      secrets_b = for _ <- 1..2, do: unique_secret()

      Enum.each(secrets_a, fn s -> :ok = Spent.mark_spent(s, kid_a) end)
      Enum.each(secrets_b, fn s -> :ok = Spent.mark_spent(s, kid_b) end)

      Enum.each(secrets_a ++ secrets_b, fn s -> assert Spent.spent?(s) end)

      {:ok, counts} = Spent.compact_keyset(kid_a)
      assert counts.ets >= 3

      Enum.each(secrets_a, fn s -> refute Spent.spent?(s) end)
      Enum.each(secrets_b, fn s -> assert Spent.spent?(s) end)
    end

    test "refuses to compact an unknown keyset (guard covers accidental misuse)" do
      # L9 defense-in-depth: compact_keyset refuses non-expired
      # keysets so a future caller can't accidentally wipe the guard
      # for an active keyset. Unknown keyset_id returns :not_found
      # from the Store which the guard treats as unsafe.
      assert {:error, {:keyset_not_expired, :not_found}} =
               Spent.compact_keyset("nonexistent_#{:erlang.unique_integer([:positive])}")
    end

    test "refuses to compact an active keyset" do
      kid = install_active_keyset()
      :ok = Spent.mark_spent(unique_secret(), kid)

      assert {:error, {:keyset_not_expired, :active}} = Spent.compact_keyset(kid)
    end
  end

  defp install_active_keyset do
    keyset = Keyset.generate()
    :ok = StorageFacade.put_keyset(Keyset.to_store_map(keyset))
    keyset.id
  end

  defp install_expired_keyset do
    kid = install_active_keyset()
    :ok = StorageFacade.expire_keyset(kid)
    kid
  end

  describe "count/0" do
    test "reflects the number of spent entries" do
      initial = Spent.count()
      keyset_id = unique_keyset_id()

      :ok = Spent.mark_spent(unique_secret(), keyset_id)
      :ok = Spent.mark_spent(unique_secret(), keyset_id)

      assert Spent.count() == initial + 2
    end
  end

  describe "clear/0" do
    test "removes all spent entries" do
      keyset_id = unique_keyset_id()
      secret = unique_secret()

      :ok = Spent.mark_spent(secret, keyset_id)
      assert Spent.spent?(secret)

      :ok = Spent.clear()
      refute Spent.spent?(secret)
      assert Spent.count() == 0
    end
  end
end
