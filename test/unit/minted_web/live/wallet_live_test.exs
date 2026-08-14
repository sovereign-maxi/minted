# Unit test
defmodule MintedWeb.WalletLiveTest do
  @moduledoc "Unit tests for MintedWeb.WalletLive event handlers."

  use ExUnit.Case, async: true

  alias MintedWeb.WalletLive

  defp bare_socket, do: %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}}}

  describe "wallet:state expansion budget" do
    test "a huge denomination map is rejected, not expanded" do
      params = %{
        "balance" => 0,
        "token_count" => 0,
        "tokens_by_denom" => Map.new(1..5_000, &{Integer.to_string(&1), 1_000}),
        "activities" => []
      }

      assert {:noreply, socket} = WalletLive.handle_event("wallet:state", params, bare_socket())

      # The update is dropped entirely — no tokens assign landed.
      refute Map.has_key?(socket.assigns, :tokens)
    end

    test "a within-budget map expands normally" do
      params = %{
        "balance" => 3,
        "token_count" => 3,
        "tokens_by_denom" => %{"1" => 2, "2" => 1},
        "activities" => []
      }

      assert {:noreply, socket} = WalletLive.handle_event("wallet:state", params, bare_socket())
      assert length(socket.assigns[:tokens]) == 3
    end

    test "per-denomination caps still apply" do
      params = %{
        "balance" => 0,
        "token_count" => 0,
        "tokens_by_denom" => %{"2" => 1_001},
        "activities" => []
      }

      assert {:noreply, socket} = WalletLive.handle_event("wallet:state", params, bare_socket())
      refute Map.has_key?(socket.assigns, :tokens)
    end
  end
end
