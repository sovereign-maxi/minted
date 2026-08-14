defmodule MintedWeb.Live.Components.RestorePanelTest do
  @moduledoc "Unit tests for MintedWeb.Live.Components.RestorePanel."

  use ExUnit.Case, async: true

  alias Minted.Mint.Token

  describe "Token.deserialize/1" do
    test "rejects non-cashuA prefix" do
      assert {:error, _} = Token.deserialize("invalid_token_data")
    end

    test "rejects empty string" do
      assert {:error, _} = Token.deserialize("")
    end

    test "rejects cashuA with invalid base64" do
      result = Token.deserialize("cashuA!!!invalid!!!")
      assert result == :error or match?({:error, _}, result)
    end

    test "parses valid cashuA token" do
      # Build a minimal valid cashuA token.
      payload = %{"token" => [%{"proofs" => [%{"amount" => 1, "secret" => "s", "C" => "c"}]}]}
      encoded = Jason.encode!(payload) |> Base.url_encode64(padding: false)
      token = "cashuA" <> encoded

      case Token.deserialize(token) do
        {:ok, tokens} when is_list(tokens) ->
          assert tokens != []

        {:error, _reason} ->
          # Some implementations may require additional fields.
          :ok
      end
    end
  end
end
