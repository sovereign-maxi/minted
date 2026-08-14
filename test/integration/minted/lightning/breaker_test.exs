defmodule Minted.Lightning.BreakerIntegrationTest do
  @moduledoc "Integration tests for lightning circuit breaker state transitions."

  use Minted.IntegrationCase

  alias Minted.Lightning.Breaker

  setup do
    # Ensure the Breaker GenServer is running.
    case Process.whereis(Breaker) do
      nil -> {:ok, _} = Breaker.start_link()
      _pid -> :ok
    end

    :ok
  end

  describe "closed state" do
    test "allows calls through when circuit is closed" do
      key = :"cb_closed_#{:erlang.unique_integer([:positive])}"
      result = Breaker.call(key, fn -> {:ok, :success} end)
      assert result == {:ok, :success}
    end

    test "passes through error results without opening on few failures" do
      key = :"cb_err_#{:erlang.unique_integer([:positive])}"
      result = Breaker.call(key, fn -> {:error, :timeout} end)
      assert result == {:error, :timeout}
    end
  end

  describe "open state" do
    test "opens after threshold consecutive failures" do
      key = :"cb_open_#{:erlang.unique_integer([:positive])}"

      for _i <- 1..5 do
        Breaker.call(key, fn -> {:error, :fail} end)
      end

      assert {:error, :circuit_open} = Breaker.call(key, fn -> {:ok, :blocked} end)
    end
  end

  describe "success resets" do
    test "success resets failure counter" do
      key = :"cb_reset_#{:erlang.unique_integer([:positive])}"

      for _i <- 1..4 do
        Breaker.call(key, fn -> {:error, :fail} end)
      end

      Breaker.call(key, fn -> {:ok, :reset} end)

      for _i <- 1..4 do
        Breaker.call(key, fn -> {:error, :fail} end)
      end

      result = Breaker.call(key, fn -> {:ok, :still_closed} end)
      assert result == {:ok, :still_closed}
    end
  end

  describe "circuit isolation" do
    test "different keys have independent circuits" do
      key_a = :"cb_iso_a_#{:erlang.unique_integer([:positive])}"
      key_b = :"cb_iso_b_#{:erlang.unique_integer([:positive])}"

      # Open circuit A
      for _i <- 1..5 do
        Breaker.call(key_a, fn -> {:error, :fail} end)
      end

      assert {:error, :circuit_open} = Breaker.call(key_a, fn -> {:ok, :blocked} end)

      # Circuit B should still work
      result = Breaker.call(key_b, fn -> {:ok, :independent} end)
      assert result == {:ok, :independent}
    end
  end

  describe "function execution" do
    test "returns the function's result on success" do
      key = :"cb_exec_#{:erlang.unique_integer([:positive])}"
      assert {:ok, 42} = Breaker.call(key, fn -> {:ok, 42} end)
    end

    test "returns the function's error on failure" do
      key = :"cb_exec_err_#{:erlang.unique_integer([:positive])}"
      assert {:error, :custom_reason} = Breaker.call(key, fn -> {:error, :custom_reason} end)
    end
  end
end
