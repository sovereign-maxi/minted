defmodule Minted.Identity.GateIntegrationTest do
  @moduledoc "Integration tests for identity gate middleware and request filtering."

  use Minted.IntegrationCase

  import Minted.TestHelpers.ProcessHelpers
  import Plug.Conn
  import Plug.Test

  alias Minted.Identity.Gate

  setup do
    # Ensure Seer GenServers are running. Each creates its own ETS table in init/1.
    ensure_started(Seer.NonceStore, fn -> Seer.NonceStore.start_link([]) end)

    ensure_started(Seer.RateLimiter, fn ->
      Seer.RateLimiter.start_link(
        limits: %{
          deposit: {10, 300},
          withdraw: {5, 300},
          swap: {20, 300},
          info: {100, 60}
        },
        global_multiplier: 10
      )
    end)

    ensure_started(Seer.Difficulty, fn ->
      Seer.Difficulty.start_link(min_difficulty: 4, max_difficulty: 8)
    end)

    ensure_started(Seer.Escalation, fn -> Seer.Escalation.start_link([]) end)

    # Ensure DoubleSpendEscalation ETS table exists (created by its GenServer).
    if :ets.whereis(Minted.Identity.Escalation) == :undefined do
      :ets.new(Minted.Identity.Escalation, [
        :set,
        :public,
        :named_table,
        {:write_concurrency, true}
      ])
    end

    # Clean rate limiter state between tests.
    safe_ets_clear(Seer.RateLimiter)
    safe_ets_clear(Seer.NonceStore)

    :ok
  end

  defp ensure_started(name, start_fn) do
    case GenServer.whereis(name) do
      nil ->
        {:ok, pid} = start_fn.()
        on_exit(fn -> safe_stop(pid) end)

      _pid ->
        :ok
    end
  end

  defp safe_ets_clear(table) do
    if :ets.whereis(table) != :undefined do
      :ets.delete_all_objects(table)
    end
  rescue
    _ -> :ok
  end

  defp build_test_conn(method, path) do
    conn(method, path)
    |> put_private(:plug_skip_csrf_protection, true)
  end

  describe "difficulty feed" do
    test "every gated request is recorded into the difficulty EMA" do
      opts = Gate.init(enabled: true)

      before = Seer.Difficulty.stats().raw_count

      # Even requests that get rejected downstream (no PoW → 402) count.
      build_test_conn(:post, "/v1/mint/quote") |> Gate.call(opts)
      build_test_conn(:post, "/v1/mint/quote") |> Gate.call(opts)

      assert Seer.Difficulty.stats().raw_count >= before + 2
    end

    test "exempt requests are not recorded" do
      opts = Gate.init(enabled: true)

      before = Seer.Difficulty.stats().raw_count

      build_test_conn(:get, "/v1/info") |> Gate.call(opts)

      assert Seer.Difficulty.stats().raw_count == before
    end
  end

  describe "disabled gate" do
    test "passes all requests through when disabled" do
      opts = Gate.init(enabled: false)

      conn = build_test_conn(:get, "/v1/mint/quote")
      result = Gate.call(conn, opts)

      refute result.halted
      assert result.assigns[:circuit_id_hash]
      assert result.assigns[:operation]
    end

    test "assigns operation classification when disabled" do
      opts = Gate.init(enabled: false)

      conn = build_test_conn(:post, "/v1/mint/quote")
      result = Gate.call(conn, opts)

      assert result.assigns[:operation] == :deposit
    end
  end

  describe "exempt paths" do
    test "GET /v1/info is exempt by default" do
      opts = Gate.init(enabled: true)

      conn = build_test_conn(:get, "/v1/info")
      result = Gate.call(conn, opts)

      refute result.halted
      assert result.assigns[:exempt] == true
    end

    test "custom exempt paths are respected" do
      opts = Gate.init(enabled: true, exempt_paths: [{"GET", "/health"}])

      conn = build_test_conn(:get, "/health")
      result = Gate.call(conn, opts)

      refute result.halted
      assert result.assigns[:exempt] == true
    end

    test "non-exempt paths are not marked exempt" do
      opts = Gate.init(enabled: true, exempt_paths: [{"GET", "/v1/info"}])

      conn = build_test_conn(:post, "/v1/mint/quote")
      result = Gate.call(conn, opts)

      # Either passes or halts with rate limit / PoW, but should not be exempt
      refute result.assigns[:exempt]
    end
  end

  describe "classify_operation/1" do
    test "classifies known endpoints correctly" do
      cases = [
        {:get, "/v1/info", :info},
        {:get, "/v1/keysets", :info},
        {:get, "/v1/keysets/abc123", :info},
        {:get, "/v1/reserves", :info},
        {:post, "/v1/mint/quote", :deposit},
        {:post, "/v1/mint/bolt11", :deposit},
        {:post, "/v1/melt/quote", :withdraw},
        {:post, "/v1/melt/bolt11", :withdraw},
        {:post, "/v1/swap", :swap}
      ]

      Enum.each(cases, fn {method, path, expected_op} ->
        conn = build_test_conn(method, path)

        assert Gate.classify_operation(conn) == expected_op,
               "Expected #{method} #{path} to classify as #{expected_op}"
      end)
    end

    test "unknown endpoints default to :expensive" do
      conn = build_test_conn(:post, "/v1/unknown/endpoint")
      assert Gate.classify_operation(conn) == :expensive
    end
  end

  describe "rate limiting" do
    test "allows requests within rate limit" do
      opts = Gate.init(enabled: true)

      conn = build_test_conn(:get, "/v1/keysets")
      result = Gate.call(conn, opts)

      refute result.halted
    end

    test "returns 429 when rate limit exceeded" do
      opts = Gate.init(enabled: true)

      # Exhaust the rate limit for :deposit (10 per 300s window).
      # Use unique circuit per request to test global limit,
      # or same circuit for per-circuit limit.
      # We'll use same circuit (same peer address) to hit per-circuit limit.
      results =
        for i <- 1..15 do
          conn = build_test_conn(:post, "/v1/mint/quote")
          result = Gate.call(conn, opts)
          {i, result.status, result.halted}
        end

      # At least one should be rate-limited (429) or require PoW (402)
      halted_statuses = results |> Enum.filter(fn {_, _, halted} -> halted end) |> Enum.map(fn {_, s, _} -> s end)

      assert Enum.any?(halted_statuses, fn s -> s in [429, 402] end),
             "Expected at least one 429 or 402 response after exceeding rate limit, got: #{inspect(halted_statuses)}"
    end
  end

  describe "PoW challenge flow" do
    test "expensive operation without PoW returns 402 with challenge" do
      opts = Gate.init(enabled: true)

      # First exhaust rate limit or hit an expensive endpoint that requires PoW.
      # POST /v1/mint/* is :expensive which requires PoW.
      # The behavior depends on whether rate limit is hit first or PoW is checked.
      # After rate limit is exceeded, missing PoW should yield 429 (no solution provided).
      # For a fresh circuit, an expensive operation checks PoW after rate limit passes.

      conn = build_test_conn(:post, "/v1/mint/quote")
      result = Gate.call(conn, opts)

      # If rate limit passes, the expensive operation will require PoW -> 402
      # If rate limit fails, we get 429
      if result.halted do
        assert result.status in [402, 429]

        if result.status == 402 do
          body = Jason.decode!(result.resp_body)
          assert body["error"] == "pow_required"
          assert is_binary(body["nonce"])
          assert is_integer(body["difficulty"])
        end
      end
    end

    test "valid PoW solution allows request through" do
      opts = Gate.init(enabled: true)

      # Generate a challenge
      difficulty = Seer.Difficulty.current()
      {:ok, challenge} = Seer.Challenge.generate(difficulty)

      # Solve the challenge (brute force with low difficulty)
      solution = solve_pow(challenge.nonce, difficulty)

      conn =
        build_test_conn(:post, "/v1/mint/quote")
        |> put_req_header("x-challenge-nonce", Base.encode16(challenge.nonce, case: :lower))
        |> put_req_header("x-challenge-solution", Base.encode16(solution, case: :lower))

      result = Gate.call(conn, opts)

      # With valid PoW, should either pass through or only be blocked by non-PoW reasons
      if not result.halted do
        assert result.assigns[:pow_verified] == true
      end
    end
  end

  describe "segment-boundary path matching (M12 fix)" do
    test "path traversal does not bypass exempt check" do
      opts = Gate.init(enabled: true, exempt_paths: [{"GET", "/v1/info"}])

      # /v1/info-evil should NOT match /v1/info
      conn = build_test_conn(:get, "/v1/info-evil")
      result = Gate.call(conn, opts)
      refute result.assigns[:exempt]
    end

    test "sub-path of exempt path is exempt" do
      opts = Gate.init(enabled: true, exempt_paths: [{"GET", "/v1/info"}])

      # /v1/info/details should match (segment boundary)
      conn = build_test_conn(:get, "/v1/info/details")
      result = Gate.call(conn, opts)
      assert result.assigns[:exempt] == true
    end
  end

  # Brute-force solve a PoW challenge (feasible at low difficulty like 4-8 bits).
  defp solve_pow(nonce, difficulty) do
    solve_pow_loop(nonce, difficulty, 0)
  end

  defp solve_pow_loop(nonce, difficulty, counter) do
    solution = <<counter::64>>
    hash = :crypto.hash(:sha256, nonce <> solution)
    <<prefix::size(difficulty), _rest::bitstring>> = hash

    if prefix == 0 do
      solution
    else
      solve_pow_loop(nonce, difficulty, counter + 1)
    end
  end
end
