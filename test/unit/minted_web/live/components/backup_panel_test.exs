defmodule MintedWeb.Live.Components.BackupPanelTest do
  @moduledoc "Unit tests for MintedWeb.Live.Components.BackupPanel."

  use ExUnit.Case, async: true

  alias Minted.Mint.Token

  describe "Token.serialize/1" do
    test "serializes to cashuA format" do
      tokens = [%Token{amount: 1, secret: "s1", c: "c1", keyset_id: "ks1"}]
      result = Token.serialize(tokens)
      assert {:ok, cashu_string} = result
      assert String.starts_with?(cashu_string, "cashuA")
    end

    test "serializes empty token list" do
      result = Token.serialize([])
      assert {:ok, cashu_string} = result
      assert String.starts_with?(cashu_string, "cashuA")
    end

    test "produces valid base64url after prefix" do
      tokens = [%Token{amount: 1, secret: "s1", c: "c1", keyset_id: "ks1"}]
      {:ok, result} = Token.serialize(tokens)
      base64_part = String.trim_leading(result, "cashuA")
      assert {:ok, _} = Base.url_decode64(base64_part, padding: false)
    end
  end
end
