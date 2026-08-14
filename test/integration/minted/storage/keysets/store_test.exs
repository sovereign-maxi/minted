defmodule Minted.Storage.Keysets.StoreIntegrationTest do
  @moduledoc """
  Integration tests for Keysets.Store GenServer:
  put, get, get_active, rotate, expire, and ETS consistency.
  """

  use Minted.IntegrationCase

  import Minted.TestHelpers.ProcessHelpers

  alias Minted.Storage.Holder
  alias Minted.Storage.Keysets.Store

  @ets_table Minted.Storage.Keysets.Store

  defp unique_id do
    "ks_#{:erlang.unique_integer([:positive, :monotonic])}"
  end

  defp make_keyset(opts \\ []) do
    id = Keyword.get(opts, :id, unique_id())
    active = Keyword.get(opts, :active, true)

    %{
      id: id,
      public_keys: %{1 => "pub_key_1_#{id}", 2 => "pub_key_2_#{id}"},
      private_keys: %{1 => "priv_key_1_#{id}", 2 => "priv_key_2_#{id}"},
      active: active,
      expired: false,
      created_at: System.system_time(:millisecond)
    }
  end

  setup do
    # The keyset ETS table is :protected and owned by Minted.Storage.Holder,
    # which is started as part of the application supervision tree before
    # tests run. All test writes must go through Holder.delete_all_objects/1
    # rather than :ets.delete_all_objects/1 which would fail with
    # "insufficient access rights" since the test process is not the owner.
    Holder.delete_all_objects(@ets_table)

    # Set up a temp WAL directory and start a WAL server.
    wal_dir = Path.join(System.tmp_dir!(), "minted_ks_wal_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(wal_dir)

    wal_name = :"wal_test_#{:erlang.unique_integer([:positive, :monotonic])}"

    wal_types = %{
      keyset_created: 0x01,
      keyset_rotated: 0x02,
      keyset_expired: 0x03,
      checkpoint: 0x06
    }

    {:ok, wal_pid} =
      Locker.WAL.start_link(
        wal_dir: wal_dir,
        types: wal_types,
        name: wal_name
      )

    ks_name = :"keyset_store_#{:erlang.unique_integer([:positive, :monotonic])}"

    # Clear the ETS table before starting Store (it will replay WAL).
    Holder.delete_all_objects(@ets_table)

    {:ok, ks_pid} =
      Store.start_link(
        name: ks_name,
        wal_server: wal_name,
        ets_table: @ets_table
      )

    on_exit(fn ->
      safe_stop(ks_pid)
      safe_stop(wal_pid)
      File.rm_rf(wal_dir)
    end)

    %{ks_name: ks_name, wal_name: wal_name, wal_dir: wal_dir}
  end

  describe "put and get" do
    test "stores a keyset and retrieves it by ID", %{ks_name: ks_name} do
      keyset = make_keyset()

      assert :ok = Store.put(ks_name, keyset)
      assert {:ok, stored} = Store.get(keyset.id)
      assert stored.id == keyset.id
      assert stored.public_keys == keyset.public_keys
      assert stored.active == true
      assert stored.expired == false
    end

    test "returns not_found for unknown keyset ID" do
      assert :not_found = Store.get("nonexistent_#{unique_id()}")
    end

    test "put sets created_at and active defaults", %{ks_name: ks_name} do
      keyset = %{
        id: unique_id(),
        public_keys: %{1 => "pub"},
        private_keys: %{1 => "priv"}
      }

      assert :ok = Store.put(ks_name, keyset)
      {:ok, stored} = Store.get(keyset.id)
      assert stored.active == true
      assert stored.expired == false
      assert is_integer(stored.created_at)
    end
  end

  describe "get_active" do
    test "returns only active, non-expired keysets", %{ks_name: ks_name} do
      active1 = make_keyset(active: true)
      active2 = make_keyset(active: true)
      inactive = make_keyset(active: false)

      :ok = Store.put(ks_name, active1)
      :ok = Store.put(ks_name, active2)
      :ok = Store.put(ks_name, inactive)

      active_list = Store.get_active()
      active_ids = Enum.map(active_list, & &1.id) |> MapSet.new()

      # The initial keyset auto-generated on startup is also active,
      # so filter to only our test keysets.
      assert MapSet.member?(active_ids, active1.id)
      assert MapSet.member?(active_ids, active2.id)
      refute MapSet.member?(active_ids, inactive.id)
    end
  end

  describe "rotate" do
    test "retires old keyset and activates new one", %{ks_name: ks_name} do
      old_keyset = make_keyset()
      :ok = Store.put(ks_name, old_keyset)

      # Verify old keyset is active.
      {:ok, before_rotate} = Store.get(old_keyset.id)
      assert before_rotate.active == true

      new_keyset = make_keyset()
      assert :ok = Store.rotate(ks_name, old_keyset.id, new_keyset)

      # Old keyset should be retired (active: false).
      {:ok, rotated_old} = Store.get(old_keyset.id)
      assert rotated_old.active == false

      # New keyset should be active.
      {:ok, rotated_new} = Store.get(new_keyset.id)
      assert rotated_new.active == true
      assert rotated_new.expired == false
    end

    test "returns error when rotating nonexistent keyset", %{ks_name: ks_name} do
      new_keyset = make_keyset()

      assert {:error, :keyset_not_found} =
               Store.rotate(ks_name, "nonexistent_id", new_keyset)
    end

    test "full rotation cycle: put -> rotate -> verify ETS consistency", %{ks_name: ks_name} do
      ks1 = make_keyset()
      :ok = Store.put(ks_name, ks1)

      ks2 = make_keyset()
      :ok = Store.rotate(ks_name, ks1.id, ks2)

      ks3 = make_keyset()
      :ok = Store.rotate(ks_name, ks2.id, ks3)

      # ks1 and ks2 should be inactive, ks3 active.
      {:ok, s1} = Store.get(ks1.id)
      {:ok, s2} = Store.get(ks2.id)
      {:ok, s3} = Store.get(ks3.id)

      refute s1.active
      refute s2.active
      assert s3.active

      # ETS should contain all three.
      all = Store.list()
      all_ids = Enum.map(all, & &1.id) |> MapSet.new()
      assert MapSet.member?(all_ids, ks1.id)
      assert MapSet.member?(all_ids, ks2.id)
      assert MapSet.member?(all_ids, ks3.id)
    end
  end

  describe "expire" do
    test "marks keyset as expired and destroys private keys", %{ks_name: ks_name} do
      keyset = make_keyset()
      :ok = Store.put(ks_name, keyset)

      assert :ok = Store.expire(ks_name, keyset.id)

      {:ok, expired} = Store.get(keyset.id)
      assert expired.active == false
      assert expired.expired == true

      # Private keys should be destroyed (sentinel values).
      Enum.each(expired.private_keys, fn {_denom, val} ->
        assert val == :destroyed
      end)
    end

    test "expired keyset does not appear in get_active", %{ks_name: ks_name} do
      keyset = make_keyset()
      :ok = Store.put(ks_name, keyset)
      :ok = Store.expire(ks_name, keyset.id)

      active_ids = Store.get_active() |> Enum.map(& &1.id) |> MapSet.new()
      refute MapSet.member?(active_ids, keyset.id)
    end

    test "returns error for nonexistent keyset", %{ks_name: ks_name} do
      assert {:error, :keyset_not_found} =
               Store.expire(ks_name, "nonexistent_#{unique_id()}")
    end
  end

  describe "ETS consistency" do
    test "direct ETS reads match GenServer-mediated writes", %{ks_name: ks_name} do
      keyset = make_keyset()
      :ok = Store.put(ks_name, keyset)

      # Direct ETS read.
      keyset_id = keyset.id
      [{^keyset_id, ets_keyset}] = :ets.lookup(@ets_table, keyset.id)

      assert ets_keyset.id == keyset.id
      assert ets_keyset.public_keys == keyset.public_keys
      assert ets_keyset.active == true
    end

    test "list returns all keysets from ETS", %{ks_name: ks_name} do
      ks1 = make_keyset()
      ks2 = make_keyset()
      :ok = Store.put(ks_name, ks1)
      :ok = Store.put(ks_name, ks2)

      all = Store.list()
      all_ids = Enum.map(all, & &1.id) |> MapSet.new()
      assert MapSet.member?(all_ids, ks1.id)
      assert MapSet.member?(all_ids, ks2.id)
    end
  end

  describe "WAL replay hardening" do
    test "refuses a keyset_created entry carrying plaintext private keys", %{
      wal_name: wal_name
    } do
      # Every legitimate write path encrypts private keys before append,
      # so an unencrypted entry on disk is forged (or a relic). Replay
      # must halt, not install it.
      forged = %{
        id: "forged_plaintext",
        unit: "sat",
        active: true,
        expired: false,
        public_keys: %{1 => "pub"},
        private_keys: %{1 => "attacker_known_privkey"},
        created_at: System.system_time(:millisecond)
      }

      :ok = Locker.WAL.append(wal_name, %Locker.WAL.Entry{type: :keyset_created, payload: forged})

      new_name = :"keyset_store_#{:erlang.unique_integer([:positive, :monotonic])}"

      # Unlinked start: the init crash returns as {:error, reason}
      # instead of an exit signal to the test process.
      assert {:error, {%Store.PlaintextKeysInWal{message: msg}, _stack}} =
               GenServer.start(Store, [wal_server: wal_name, ets_table: @ets_table], name: new_name)

      assert msg =~ "Plaintext private keys"
    end
  end
end
