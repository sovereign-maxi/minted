defmodule Minted.Lightning.ExecutorIntegrationTest do
  @moduledoc """
  Integration tests for Executor: execute with mock client,
  concurrent payment limiting, and ETS in-flight tracking.
  """

  use Minted.IntegrationCase

  import Mox
  import Minted.TestHelpers.ProcessHelpers

  alias Minted.Lightning.Executor
  alias Minted.Lightning.Payment
  alias Minted.Lightning.PhoenixdMock

  setup :set_mox_global
  setup :verify_on_exit!

  @max_concurrent 5

  # A bolt11 string long enough and with valid prefix to pass preflight validation.
  # Amount encoding: lnbc1000n means 1000 nano-BTC = 100 sats (but Bolt11.parse_amount
  # needs a real encoding). We use a zero-amount invoice prefix so the amount check passes.
  defp make_bolt11(suffix) do
    # lnbc1 means a zero-amount invoice; parse_amount returns {:ok, 0} which matches any amount.
    padding = String.duplicate("x", 60)
    "lnbc1#{padding}#{suffix}"
  end

  defp make_payment(opts \\ []) do
    bolt11 = Keyword.get(opts, :bolt11, make_bolt11("#{:erlang.unique_integer([:positive])}"))
    amount = Keyword.get(opts, :amount_sats, 1000)
    max_attempts = Keyword.get(opts, :max_attempts, 3)

    Payment.new(
      bolt11: bolt11,
      amount_sats: amount,
      max_attempts: max_attempts,
      fee_limit_sats: 100
    )
  end

  setup do
    # Ensure the in-flight ETS table is clean.
    case :ets.whereis(Minted.Lightning.Executor.InFlight) do
      :undefined -> :ok
      _ref -> :ets.delete_all_objects(Minted.Lightning.Executor.InFlight)
    end

    case :ets.whereis(Minted.Lightning.Executor.IdMap) do
      :undefined -> :ok
      _ref -> :ets.delete_all_objects(Minted.Lightning.Executor.IdMap)
    end

    case :ets.whereis(Minted.Lightning.Executor) do
      :undefined -> :ok
      _ref -> :ets.delete_all_objects(Minted.Lightning.Executor)
    end

    :ok
  end

  describe "execute with mock client" do
    test "submits payment and transitions to in_flight" do
      payment = make_payment()
      test_pid = self()

      # pay_invoice runs inside a fire-and-forget Task; the stub signals the
      # test process so we can wait for that Task before the test exits. Without
      # this sync, the Task can call the mock after the next test starts and
      # trip Mox.UnexpectedCallError under set_mox_global.
      stub(PhoenixdMock, :pay_invoice, fn _config, _bolt11, _amt, _desc, _fee ->
        send(test_pid, :pay_invoice_done)
        {:ok, %{"preimage" => "abc123", "routingFeeSat" => 2}}
      end)

      assert {:ok, in_flight} = Executor.execute(payment)
      assert in_flight.status == :in_flight
      assert in_flight.id == payment.id

      assert_receive :pay_invoice_done, 1_000
    end

    test "rejects invalid bolt11 prefix" do
      payment = %{make_payment() | bolt11: "invalid_not_lnbc"}

      assert {:error, :invalid_bolt11} = Executor.execute(payment)
    end

    test "rejects bolt11 that is too short" do
      payment = %{make_payment() | bolt11: "lnbc1short"}

      assert {:error, :invalid_bolt11} = Executor.execute(payment)
    end

    test "forwards fee_limit_sats through to the client" do
      payment = %{make_payment() | fee_limit_sats: 77}
      test_pid = self()

      stub(PhoenixdMock, :pay_invoice, fn _config, _bolt11, _amt, _desc, fee_limit ->
        send(test_pid, {:pay_invoice_fee_limit, fee_limit})
        {:ok, %{"preimage" => "abc123", "routingFeeSat" => 2}}
      end)

      assert {:ok, _in_flight} = Executor.execute(payment)
      assert_receive {:pay_invoice_fee_limit, 77}, 1_000
    end
  end

  describe "concurrent payment limiting" do
    test "allows up to max_concurrent payments" do
      # Use a stub that delays so payments stay in-flight.
      test_pid = self()

      stub(PhoenixdMock, :pay_invoice, fn _config, _bolt11, _amt, _desc, _fee ->
        send(test_pid, :payment_started)
        # Block so the flight slot stays occupied.
        receive do
          :release -> {:ok, %{"preimage" => "abc", "routingFeeSat" => 0}}
        after
          5_000 -> {:error, :timeout}
        end
      end)

      # Submit max_concurrent payments.
      results =
        for _ <- 1..@max_concurrent do
          payment = make_payment()
          Executor.execute(payment)
        end

      # All should succeed.
      assert Enum.all?(results, fn
               {:ok, %Payment{status: :in_flight}} -> true
               _ -> false
             end)

      # Wait for every Task to enter the stub body. Once they are inside the
      # stub, the Mox lookup is complete; the receive timeout below cannot
      # trigger another mock call. Without this sync, Tasks scheduled after
      # the test exits would fail Mox lookup once the test process is gone.
      for _ <- 1..@max_concurrent do
        assert_receive :payment_started, 1_000
      end

      # Verify the count key in ETS.
      in_flight_table = Minted.Lightning.Executor.InFlight

      await_condition(fn ->
        case :ets.lookup(in_flight_table, :count_in_flight) do
          [{:count_in_flight, count}] -> count == @max_concurrent
          _ -> false
        end
      end)

      # The next payment should be rejected.
      extra_payment = make_payment()
      assert {:error, :too_many_concurrent} = Executor.execute(extra_payment)
    end
  end

  describe "ETS id_map tracking" do
    test "stores forward and reverse mappings after execute" do
      test_pid = self()

      stub(PhoenixdMock, :pay_invoice, fn _config, _bolt11, _amt, _desc, _fee ->
        send(test_pid, :pay_invoice_done)
        {:ok, %{"preimage" => "abc", "routingFeeSat" => 0}}
      end)

      payment = make_payment()
      {:ok, _in_flight} = Executor.execute(payment)

      id_map = Minted.Lightning.Executor.IdMap

      # Verify we can look up payment_id by FireBird hash.
      fb_hash = :crypto.hash(:sha256, payment.bolt11)

      await_condition(fn ->
        case :ets.lookup(id_map, fb_hash) do
          [{^fb_hash, pid}] -> pid == payment.id
          _ -> false
        end
      end)

      # Verify reverse lookup.
      assert [{_, ^fb_hash}] = :ets.lookup(id_map, {:reverse, payment.id})

      assert_receive :pay_invoice_done, 1_000
    end
  end

  describe "lookup_payment_id" do
    test "returns payment_id for known hash" do
      test_pid = self()

      stub(PhoenixdMock, :pay_invoice, fn _config, _bolt11, _amt, _desc, _fee ->
        send(test_pid, :pay_invoice_done)
        {:ok, %{"preimage" => "abc", "routingFeeSat" => 0}}
      end)

      payment = make_payment()
      {:ok, _in_flight} = Executor.execute(payment)

      fb_hash = :crypto.hash(:sha256, payment.bolt11)

      await_condition(fn ->
        Executor.lookup_payment_id(fb_hash) == payment.id
      end)

      assert_receive :pay_invoice_done, 1_000
    end

    test "returns hex-encoded hash for unknown hash" do
      unknown_hash = :crypto.strong_rand_bytes(32)
      result = Executor.lookup_payment_id(unknown_hash)
      assert result == Base.encode16(unknown_hash, case: :lower)
    end
  end
end
