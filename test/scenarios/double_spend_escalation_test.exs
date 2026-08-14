defmodule Minted.Scenarios.DoubleSpendEscalationTest do
  @moduledoc """
  Pins the wire between double-spend responses and rate-limit
  escalation. The mint layer publishes `DoubleSpendDetected` for
  observability (single AND batch paths), but ESCALATION happens at
  the request boundary — `MintedWeb.FallbackController` calls
  `Escalation.record/1` with `conn.assigns.circuit_id_hash`, which is
  the identifier the rate limiter actually keys on.

  Before this rewire, Escalation subscribed to `DoubleSpendDetected`
  and stored multipliers under `secret_hash`. The rate limiter keys
  on `circuit_id_hash`. The two never lined up — escalation was
  silently dead. This test suite makes sure that regression can't
  come back.
  """

  use ExUnit.Case, async: false

  @moduletag :scenario

  import Minted.TestHelpers.ProcessHelpers
  import Plug.Test

  alias Minted.Identity.Escalation
  alias MintedWeb.FallbackController

  setup do
    Minted.TestHelpers.StateHelpers.clean_state(%{})

    case GenServer.whereis(Seer.RateLimiter) do
      nil ->
        {:ok, rl_pid} =
          Seer.RateLimiter.start_link(
            limits: %{deposit: {10, 300}, withdraw: {5, 300}, swap: {20, 300}, info: {100, 60}},
            global_multiplier: 10
          )

        on_exit(fn -> safe_stop(rl_pid) end)

      _pid ->
        :ok
    end

    case GenServer.whereis(Escalation) do
      nil ->
        {:ok, esc_pid} = Escalation.start_link()
        on_exit(fn -> safe_stop(esc_pid) end)
        :ok

      _pid ->
        :ets.delete_all_objects(Minted.Identity.Escalation)
        :ok
    end
  end

  describe "fallback controller escalates on double-spend responses" do
    test "already_spent escalates by circuit_id_hash" do
      circuit_id_hash = unique_circuit()

      conn = build_conn(circuit_id_hash)

      _ = FallbackController.call(conn, {:error, :already_spent})

      assert {:escalated, mult} = Escalation.status(circuit_id_hash)
      assert mult >= 3, "first double-spend must escalate rate limit multiplier"
    end

    test "batch double_spend escalates by circuit_id_hash" do
      circuit_id_hash = unique_circuit()

      conn = build_conn(circuit_id_hash)

      _ = FallbackController.call(conn, {:error, :double_spend, [<<0::256>>, <<1::256>>]})

      assert {:escalated, _mult} = Escalation.status(circuit_id_hash)
    end

    test "successive double-spends from the same circuit stack the multiplier" do
      circuit_id_hash = unique_circuit()

      for _ <- 1..3 do
        FallbackController.call(build_conn(circuit_id_hash), {:error, :already_spent})
      end

      assert {:escalated, mult} = Escalation.status(circuit_id_hash)
      # 3^3 = 27 for three attempts (base 3, capped 81).
      assert mult == 27
    end

    test "no circuit_id_hash on the conn = no crash, no escalation" do
      # A misconfigured pipeline that forgot the Gate plug shouldn't
      # crash the fallback controller. It also shouldn't escalate
      # against a nil key (there is no nil-key victim to protect).
      conn = conn(:post, "/v1/mint/quote/anything")

      _ = FallbackController.call(conn, {:error, :already_spent})

      # No assertion needed beyond "didn't raise" — but confirm no
      # phantom entry landed in the escalation table.
      assert :ok == Escalation.status(<<0::256>>)
    end
  end

  defp build_conn(circuit_id_hash) do
    conn(:post, "/v1/mint/quote/x")
    |> Plug.Conn.assign(:circuit_id_hash, circuit_id_hash)
  end

  defp unique_circuit do
    :crypto.hash(:sha256, "circuit_#{:erlang.unique_integer([:positive, :monotonic])}")
  end
end
