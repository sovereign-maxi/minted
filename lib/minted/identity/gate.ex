defmodule Minted.Identity.Gate do
  @moduledoc """
  Plug that acts as the central access control gate in the Phoenix request pipeline.

  Chains together circuit ID extraction, rate limit checking, and proof-of-work
  verification. Read-only endpoints are exempt from PoW requirements.

  Pipeline order:
  1. Extract circuit ID
  2. Classify operation
  3. Check rate limit
  4. Require PoW if needed
  5. Pass through

  ## Options

  - `:enabled` - whether the gate is active (default: true)
  - `:exempt_paths` - list of {method, path} tuples exempt from all checks
  """

  @behaviour Plug

  import Plug.Conn

  alias Seer.{Challenge, Difficulty, RateLimiter}
  alias Seer.Circuit.Extractor, as: CircuitExtractor

  @enabled Application.compile_env(:minted, [:identity, :request_gate_enabled], true)

  @default_exempt_paths [
    {"GET", "/v1/info"}
  ]

  # --- Plug Callbacks ---

  @impl true
  def init(opts) do
    %{
      enabled: Keyword.get(opts, :enabled, @enabled),
      exempt_paths: Keyword.get(opts, :exempt_paths, @default_exempt_paths)
    }
  end

  @impl true
  def call(conn, %{enabled: false}) do
    # When disabled, assign a deterministic test circuit ID.
    test_circuit_id = :crypto.hash(:sha256, "test-circuit")

    conn
    |> assign(:circuit_id_hash, test_circuit_id)
    |> assign(:operation, classify_operation(conn))
  end

  def call(conn, opts) do
    with {:ok, conn} <- extract_circuit(conn),
         {:ok, conn} <- classify_and_assign(conn, opts),
         {:ok, conn} <- apply_security_checks(conn) do
      conn
    else
      {:halt, conn} -> conn
    end
  end

  defp apply_security_checks(%{assigns: %{exempt: true}} = conn), do: {:ok, conn}

  defp apply_security_checks(conn) do
    # Feed EVERY gated request into the difficulty EMA — previously only
    # successful PoW verifies were counted, so an unauthenticated flood
    # never raised the difficulty meant to price it out.
    Difficulty.record_request()

    with {:ok, conn} <- check_rate_limit(conn) do
      check_pow_requirement(conn)
    end
  end

  # --- Private Functions ---

  defp extract_circuit(conn) do
    {:ok, circuit_id_hash} = CircuitExtractor.extract(conn)
    {:ok, assign(conn, :circuit_id_hash, circuit_id_hash)}
  end

  defp classify_and_assign(conn, opts) do
    operation = classify_operation(conn)
    conn = assign(conn, :operation, operation)

    if exempt?(conn, opts) do
      {:ok, assign(conn, :exempt, true)}
    else
      {:ok, conn}
    end
  end

  defp check_rate_limit(conn) do
    operation = conn.assigns[:operation]
    circuit_id_hash = conn.assigns[:circuit_id_hash]

    case RateLimiter.check(circuit_id_hash, operation) do
      :ok ->
        {:ok, conn}

      {:error, {:unknown_operation, _}} ->
        {:ok, conn}

      {:error, :rate_limited} ->
        # Check if client sent a PoW solution to bypass rate limit.
        case Challenge.extract_solution(conn) do
          {:ok, nonce, solution} ->
            verify_pow_solution(conn, nonce, solution)

          {:error, :missing_solution} ->
            send_429(conn)
        end

      {:error, :unavailable} ->
        # Limiter mid-restart — fail closed with 503 and surface the
        # condition through the telemetry pipeline.
        :telemetry.execute([:minted, :identity, :rate_limiter_unavailable], %{count: 1}, %{})
        send_503(conn)
    end
  end

  defp check_pow_requirement(conn) do
    # Skip if PoW was already verified during rate limit bypass.
    if conn.assigns[:pow_verified] do
      {:ok, conn}
    else
      operation = conn.assigns[:operation]

      case operation_cost(operation) do
        :expensive ->
          require_pow(conn)

        :medium ->
          maybe_require_pow(conn)

        :cheap ->
          {:ok, conn}
      end
    end
  end

  defp require_pow(conn) do
    case Challenge.extract_solution(conn) do
      {:ok, nonce, solution} ->
        verify_pow_solution(conn, nonce, solution)

      {:error, :missing_solution} ->
        send_402(conn)
    end
  end

  defp maybe_require_pow(conn) do
    difficulty = Difficulty.current()

    min_difficulty =
      Application.get_env(:minted, :identity, [])
      |> Keyword.get(:pow_min_difficulty, 12)

    if difficulty > min_difficulty do
      require_pow(conn)
    else
      {:ok, conn}
    end
  end

  # Difficulty is deliberately not passed in: Seer.Challenge.verify/2
  # reads the difficulty the nonce was ISSUED with from the nonce
  # record, so verification can never be weakened by the caller.
  defp verify_pow_solution(conn, nonce, solution) do
    case Challenge.verify(nonce, solution) do
      :ok ->
        Difficulty.record_request()
        {:ok, assign(conn, :pow_verified, true)}

      {:error, reason} ->
        send_403(conn, reason)
    end
  end

  defp send_429(conn) do
    conn =
      conn
      |> put_resp_header("retry-after", "60")
      |> put_resp_content_type("application/json")
      |> send_resp(429, Jason.encode!(%{error: "rate_limited", message: "Too many requests"}))
      |> halt()

    {:halt, conn}
  end

  defp send_503(conn) do
    conn =
      conn
      |> put_resp_header("retry-after", "5")
      |> put_resp_content_type("application/json")
      |> send_resp(
        503,
        Jason.encode!(%{error: "rate_limiter_unavailable", message: "Service temporarily unavailable"})
      )
      |> halt()

    {:halt, conn}
  end

  defp send_402(conn) do
    difficulty = Difficulty.current()
    {:ok, challenge} = Challenge.generate(difficulty)
    headers = Challenge.format_headers(challenge)

    conn =
      Enum.reduce(headers, conn, fn {key, value}, acc ->
        put_resp_header(acc, key, value)
      end)
      |> put_resp_content_type("application/json")
      |> send_resp(
        402,
        Jason.encode!(%{
          error: "pow_required",
          message: "Proof of work required",
          nonce: Base.encode16(challenge.nonce, case: :lower),
          difficulty: challenge.difficulty,
          expires_at: challenge.expires_at
        })
      )
      |> halt()

    {:halt, conn}
  end

  defp send_403(conn, reason) do
    conn =
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(
        403,
        Jason.encode!(%{error: "pow_invalid", reason: to_string(reason)})
      )
      |> halt()

    {:halt, conn}
  end

  # M12 fix: Use exact match or segment-boundary matching instead of
  # prefix matching, which allows bypass via path traversal or suffix injection.
  defp exempt?(conn, %{exempt_paths: exempt_paths}) do
    Enum.any?(exempt_paths, fn {method, path} ->
      conn.method == method and path_matches?(conn.request_path, path)
    end)
  end

  # Matches exact path or path with a trailing segment (e.g., /v1/keysets/abc)
  defp path_matches?(request_path, exempt_path) do
    request_path == exempt_path or
      String.starts_with?(request_path, exempt_path <> "/")
  end

  @doc false
  def classify_operation(conn) do
    # M12 fix: Match on path segments, not arbitrary prefixes.
    # Split on "/" and match the route prefix segments.
    case {conn.method, path_segments(conn.request_path)} do
      {"GET", ["v1", "info" | _]} -> :info
      {"GET", ["v1", "keysets" | _]} -> :info
      {"GET", ["v1", "reserves" | _]} -> :info
      {"POST", ["v1", "mint" | _]} -> :deposit
      {"POST", ["v1", "melt" | _]} -> :withdraw
      {"POST", ["v1", "swap" | _]} -> :swap
      {"POST", ["v1", "check" | _]} -> :check
      # Unknown endpoints default to expensive to prevent PoW bypass (H9)
      _ -> :expensive
    end
  end

  defp path_segments(path) do
    path |> String.split("/", trim: true)
  end

  defp operation_cost(:deposit), do: :expensive
  defp operation_cost(:withdraw), do: :expensive
  defp operation_cost(:swap), do: :medium
  defp operation_cost(:check), do: :medium
  defp operation_cost(:info), do: :cheap
  defp operation_cost(:expensive), do: :expensive
end
