defmodule Minted.Scenarios.HaltGuardTest do
  @moduledoc """
  Scenario tests for the halt guard system.

  Verifies the full lifecycle: operational → halted → rejected → recovered.
  """

  use ExUnit.Case, async: false

  @moduletag :scenario

  import Minted.TestHelpers.StateHelpers

  alias Minted.Guards
  alias Minted.Mint.Facade, as: MintFacade
  alias Minted.Telemetry.Health.System

  setup :clean_state

  setup do
    on_exit(fn -> System.clear_halt() end)
    :ok
  end

  describe "halt lifecycle" do
    test "operations succeed → system halts → operations rejected → system recovers → operations succeed" do
      # Phase 1: System is operational
      assert Guards.operational?() == true
      assert Guards.ensure_operational!() == :ok

      # Phase 2: System halts
      System.set_halted("manual_halt")
      assert Guards.operational?() == false

      assert_raise Guards.SystemHaltedError, fn ->
        Guards.ensure_operational!()
      end

      # Phase 3: Facade operations rejected
      assert_raise Guards.SystemHaltedError, fn ->
        MintFacade.create_mint_quote(1000)
      end

      # Phase 4: System recovers
      System.clear_halt()
      assert Guards.operational?() == true
      assert Guards.ensure_operational!() == :ok
    end

    test "halt reason propagates through the error" do
      System.set_halted("disk_usage_critical")

      error =
        assert_raise Guards.SystemHaltedError, fn ->
          MintFacade.sign("q", [], "k")
        end

      assert error.message =~ "disk_usage_critical"
    end

    test "multiple halt/clear cycles work correctly" do
      for reason <- ["manual_halt", "reserve_deficit", "disk_critical"] do
        System.set_halted(reason)
        assert Guards.operational?() == false

        assert_raise Guards.SystemHaltedError, ~r/#{reason}/, fn ->
          Guards.ensure_operational!()
        end

        System.clear_halt()
        assert Guards.operational?() == true
      end
    end
  end
end
