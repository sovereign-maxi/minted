defmodule MintedWeb.Live.Components.WithdrawalPanelTest do
  @moduledoc "Unit tests for MintedWeb.Live.Components.WithdrawalPanel."

  use ExUnit.Case, async: true

  alias MintedWeb.Live.Components.WithdrawalPanel

  describe "parse_bolt11_amount/1" do
    test "returns error for empty string" do
      assert {:error, _} = WithdrawalPanel.parse_bolt11_amount("")
    end

    test "parses a bolt11 invoice string" do
      result = WithdrawalPanel.parse_bolt11_amount("lnbc1000n1dummy")
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end

    test "rejects non-lnbc prefix" do
      assert {:error, "Invalid invoice: must start with lnbc."} =
               WithdrawalPanel.parse_bolt11_amount("xyzbc10u1dummy")
    end

    test "accepts lntb prefix (testnet)" do
      result = WithdrawalPanel.parse_bolt11_amount("lntb10u1pdummydata")
      assert match?({:ok, _}, result) or match?({:error, _}, result)
      refute match?({:error, "Invalid bolt11 invoice: must start with lnbc"}, result)
    end

    test "accepts lnbcrt prefix (regtest)" do
      result = WithdrawalPanel.parse_bolt11_amount("lnbcrt10u1pdummydata")
      assert match?({:ok, _}, result) or match?({:error, _}, result)
      refute match?({:error, "Invalid bolt11 invoice: must start with lnbc"}, result)
    end

    test "normalizes to lowercase before parsing" do
      result_upper = WithdrawalPanel.parse_bolt11_amount("LNBC10U1PDUMMYDATA")
      result_lower = WithdrawalPanel.parse_bolt11_amount("lnbc10u1pdummydata")
      assert result_upper == result_lower
    end

    test "trims whitespace" do
      result_trimmed = WithdrawalPanel.parse_bolt11_amount("  lnbc10u1pdummydata  ")
      result_clean = WithdrawalPanel.parse_bolt11_amount("lnbc10u1pdummydata")
      assert result_trimmed == result_clean
    end

    test "specific error message for no-amount invoice" do
      assert {:error, "Invoice does not specify an amount."} =
               WithdrawalPanel.parse_bolt11_amount("lnbc1pdummydata")
    end
  end
end
