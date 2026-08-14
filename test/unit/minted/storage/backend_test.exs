defmodule Minted.Storage.Backends.SpentTest do
  @moduledoc "Unit tests for Minted.Storage.Backends.Spent."

  use ExUnit.Case, async: true

  alias Minted.Storage.Backends.Spent, as: Backend

  describe "behaviour definition" do
    test "Backend module defines all required callbacks" do
      callbacks = Backend.behaviour_info(:callbacks)

      assert {:init, 1} in callbacks
      assert {:put, 3} in callbacks
      assert {:put_batch_sync, 2} in callbacks
      assert {:get, 2} in callbacks
      assert {:member?, 2} in callbacks
      assert {:size, 1} in callbacks
      assert {:load_all, 1} in callbacks
      assert {:delete_match, 2} in callbacks
      assert {:close, 1} in callbacks
    end

    test "Backend defines exactly nine callbacks" do
      callbacks = Backend.behaviour_info(:callbacks)
      assert length(callbacks) == 9
    end
  end
end
