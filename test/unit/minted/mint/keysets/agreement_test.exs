defmodule Minted.Mint.Keysets.AgreementTest do
  @moduledoc "Unit tests for Minted.Mint.Keysets.Agreement."

  use ExUnit.Case, async: true

  alias Minted.Mint.Keysets.Agreement

  describe "verify/1" do
    test "always returns :ok in single-node mode" do
      assert :ok = Agreement.verify("any-keyset-id")
    end
  end
end
