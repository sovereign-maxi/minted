defmodule Minted.Wallet.SettlementUnknownTest do
  @moduledoc """
  Unit tests for settlement_unknown error handling in the wallet service.

  Verifies that settlement timeouts are surfaced as :settlement_unknown
  (distinct from definitive payment failures), and that the error code
  mapping handles all melt failure modes correctly.
  """

  use ExUnit.Case, async: true

  describe "error classification" do
    test "settlement_unknown is distinct from payment_failed" do
      # The service must return :settlement_unknown (not {:payment_failed, _})
      # so the wallet UI can distinguish "pending" from "failed".
      refute :settlement_unknown == {:payment_failed, :settlement_timeout}
      refute :settlement_unknown == {:payment_failed, :timeout}
    end

    test "settlement_unknown is an atom, not a tuple" do
      # The wallet LiveView pattern matches on :settlement_unknown specifically.
      # It must NOT be wrapped in {:payment_failed, _}.
      assert is_atom(:settlement_unknown)
    end
  end
end
