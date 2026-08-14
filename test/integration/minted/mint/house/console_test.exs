defmodule Minted.Mint.House.ConsoleIntegrationTest do
  @moduledoc """
  Integration tests for `Minted.Mint.House.Console`. Covers the
  read-only `status/0` output and the register/reject stages of
  `withdraw/2` — the LN payment execution stage is exercised
  separately (requires phoenixd) and out of scope for this file.
  """

  use Minted.IntegrationCase

  import ExUnit.CaptureIO

  alias Minted.Mint.House.Console
  alias Minted.Mint.House.Facade
  alias Minted.Reserves.Trackers.Fees

  describe "status/0" do
    test "prints the accounting triad + half-cap ceiling" do
      :ok = Fees.restore_counters(100_000)

      out = capture_io(fn -> assert :ok = Console.status() end)

      assert out =~ "House Income"
      assert out =~ "Earned:"
      assert out =~ "Drawn:"
      assert out =~ "In-flight:"
      assert out =~ "Withdrawable:"
      assert out =~ "Max single request:"
      assert out =~ "half-cap rule"
    end

    test "formats the numbers via Minted.Format.format_sats" do
      :ok = Fees.restore_counters(1_234_567)

      out = capture_io(fn -> Console.status() end)

      # Expect thousand-separated formatting on 1,234,567
      assert out =~ "1,234,567"
    end
  end

  describe "withdraw/2 register stage" do
    test "prints REJECTED with the reason when register fails" do
      # No fees earned yet — any request should be rejected as
      # insufficient_withdrawable.
      out =
        capture_io(fn ->
          assert {:error, :insufficient_withdrawable} =
                   Console.withdraw(10_000, "lnbc10n1p...")
        end)

      assert out =~ "Registering withdrawal request"
      assert out =~ "REJECTED"
      assert out =~ "insufficient_withdrawable"
    end

    test "rejects half-cap violations before touching Lightning" do
      :ok = Fees.restore_counters(100_000)

      out =
        capture_io(fn ->
          assert {:error, :half_cap_exceeded} =
                   Console.withdraw(80_000, "lnbc80m1p...")
        end)

      assert out =~ "REJECTED"
      assert out =~ "half_cap_exceeded"
      # Nothing should have been in-flight because register itself failed.
      assert Facade.in_flight() == 0
    end

    test "rejects below-minimum before touching Lightning" do
      :ok = Fees.restore_counters(100_000)

      out =
        capture_io(fn ->
          assert {:error, :below_minimum} = Console.withdraw(500, "lnbc5n1p...")
        end)

      assert out =~ "below_minimum"
      assert Facade.in_flight() == 0
    end
  end

  describe "truncate/1 (invoice display)" do
    # A long invoice should get elided so the console line stays
    # readable. The middle-ellipsis format keeps prefix + suffix,
    # which is enough for the operator to eyeball a copy-paste
    # error without dumping 300 chars to the terminal.
    test "long invoices show as prefix…suffix" do
      long = String.duplicate("x", 400)

      out =
        capture_io(fn ->
          # Doesn't matter that withdraw will fail — we just want to
          # see the invoice line rendered.
          Console.withdraw(10_000, long)
        end)

      assert out =~ "Invoice:"
      # Ellipsis character indicates truncation happened.
      assert out =~ "…"
    end

    test "short invoices are printed verbatim" do
      short = "lnbc10n1p..."

      out = capture_io(fn -> Console.withdraw(10_000, short) end)

      assert out =~ short
      refute out =~ "…"
    end
  end
end
