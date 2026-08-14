defmodule Minted.Lightning.ManagerIntegrationTest do
  @moduledoc """
  Integration tests for Manager GenServer lifecycle:
  create_invoice, lookup, mark_paid, and duplicate rejection.
  """

  use Minted.IntegrationCase

  import Mox
  import Minted.TestHelpers.ProcessHelpers

  alias Minted.Lightning.Manager
  alias Minted.Lightning.PhoenixdMock

  setup :set_mox_global
  setup :verify_on_exit!

  # Generates a deterministic preimage/payment_hash pair.
  defp make_preimage_pair(seed) do
    raw = :crypto.hash(:sha256, seed)
    preimage_hex = Base.encode16(raw, case: :lower)
    hash_hex = Base.encode16(:crypto.hash(:sha256, raw), case: :lower)
    {preimage_hex, hash_hex}
  end

  setup do
    # Ensure the named ETS table exists for Manager lookups.
    if :ets.whereis(Minted.Lightning.Manager) == :undefined do
      :ets.new(Minted.Lightning.Manager, [
        :named_table,
        :set,
        :public,
        read_concurrency: true
      ])
    end

    data_dir = Path.join(System.tmp_dir!(), "minted_inv_test_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(data_dir)

    # Stub get_incoming_payment so polling doesn't crash.
    stub(PhoenixdMock, :get_incoming_payment, fn _config, _hash -> {:error, :not_found} end)

    {:ok, pid} = Manager.start_link(data_dir: data_dir, poll_interval: 60_000)

    on_exit(fn ->
      safe_stop(pid)
      File.rm_rf(data_dir)
    end)

    %{pid: pid, data_dir: data_dir}
  end

  describe "create_invoice flow" do
    test "creates an invoice via mock client and stores it" do
      {_preimage, hash_hex} = make_preimage_pair("create_test_seed")

      expect(PhoenixdMock, :create_invoice, fn _config, 5000, "test invoice", _exp ->
        {:ok, %{"paymentHash" => hash_hex, "serialized" => "lnbc5000u1p_test"}}
      end)

      assert {:ok, invoice} =
               Manager.create_invoice(5000, "test invoice", quote_id: "q-1")

      assert invoice.payment_hash == hash_hex
      assert invoice.bolt11 == "lnbc5000u1p_test"
      assert invoice.amount_sats == 5000
      assert invoice.status == :pending
      assert invoice.quote_id == "q-1"
    end

    test "returns error when client fails after retries" do
      expect(PhoenixdMock, :create_invoice, 4, fn _config, _amt, _desc, _exp ->
        {:error, :connection_refused}
      end)

      assert {:error, :connection_refused} =
               Manager.create_invoice(1000, "will fail")
    end
  end

  describe "lookup by payment_hash" do
    test "retrieves a previously created invoice" do
      {_preimage, hash_hex} = make_preimage_pair("lookup_seed")

      expect(PhoenixdMock, :create_invoice, fn _config, 2000, _desc, _exp ->
        {:ok, %{"paymentHash" => hash_hex, "serialized" => "lnbc2000u1p_test"}}
      end)

      {:ok, _inv} = Manager.create_invoice(2000, "lookup test", quote_id: "q-lookup")

      assert {:ok, found} = Manager.get_invoice(hash_hex)
      assert found.payment_hash == hash_hex
      assert found.amount_sats == 2000
    end

    test "returns not_found for unknown payment_hash" do
      assert {:error, :not_found} =
               Manager.get_invoice("0000000000000000000000000000000000000000000000000000000000000000")
    end
  end

  describe "mark_paid via webhook simulation" do
    test "marks a pending invoice as paid with valid preimage" do
      {preimage_hex, hash_hex} = make_preimage_pair("mark_paid_seed")

      expect(PhoenixdMock, :create_invoice, fn _config, 3000, _desc, _exp ->
        {:ok, %{"paymentHash" => hash_hex, "serialized" => "lnbc3000u1p_test"}}
      end)

      {:ok, _inv} = Manager.create_invoice(3000, "pay test", quote_id: "q-pay")

      # Simulate webhook: mark_paid_sync for synchronous verification.
      assert :ok = Manager.mark_paid_sync(hash_hex, preimage_hex)

      # Verify invoice now shows as paid.
      {:ok, paid} = Manager.get_invoice(hash_hex)
      assert paid.status == :paid
      assert paid.preimage == preimage_hex
    end

    test "mark_paid is idempotent for same preimage" do
      {preimage_hex, hash_hex} = make_preimage_pair("idempotent_seed")

      expect(PhoenixdMock, :create_invoice, fn _config, 1000, _desc, _exp ->
        {:ok, %{"paymentHash" => hash_hex, "serialized" => "lnbc1000u1p_test"}}
      end)

      {:ok, _inv} = Manager.create_invoice(1000, "idempotent test")
      assert :ok = Manager.mark_paid_sync(hash_hex, preimage_hex)
      # Second call should also succeed (idempotent).
      assert :ok = Manager.mark_paid_sync(hash_hex, preimage_hex)
    end

    test "returns error for unknown invoice" do
      {preimage_hex, hash_hex} = make_preimage_pair("unknown_inv_seed")

      assert {:error, :invoice_not_found} =
               Manager.mark_paid_sync(hash_hex, preimage_hex)
    end
  end

  describe "duplicate payment_hash rejection" do
    test "rejects second invoice creation with same payment_hash when quote_id differs" do
      {_preimage, hash_hex} = make_preimage_pair("dup_seed")

      # Both calls return the same payment_hash.
      expect(PhoenixdMock, :create_invoice, 2, fn _config, _amt, _desc, _exp ->
        {:ok, %{"paymentHash" => hash_hex, "serialized" => "lnbc1000u1p_dup"}}
      end)

      assert {:ok, _inv1} =
               Manager.create_invoice(1000, "first", quote_id: "q-first")

      assert {:error, :duplicate_payment_hash} =
               Manager.create_invoice(1000, "second", quote_id: "q-second")
    end
  end
end
