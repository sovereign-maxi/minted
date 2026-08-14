defmodule Minted.Telemetry.FilterTest do
  @moduledoc "Unit tests for Minted.Telemetry.Filter."

  use ExUnit.Case, async: true

  alias Minted.Telemetry.Filter

  test "filter/2 redacts sensitive keys in metadata" do
    event = %{
      level: :info,
      msg: {:string, "test"},
      meta: %{secret: "hidden_value", module: __MODULE__, pid: self()}
    }

    result = Filter.filter(event, [])

    assert result.meta.secret == "[REDACTED]"
    assert result.meta.module == __MODULE__
    assert result.meta.pid == self()
  end

  test "filter/2 passes through non-sensitive metadata" do
    event = %{
      level: :info,
      msg: {:string, "test"},
      meta: %{domain: [:minted], module: __MODULE__}
    }

    result = Filter.filter(event, [])

    assert result.meta.domain == [:minted]
    assert result.meta.module == __MODULE__
  end

  test "filter/2 handles events without meta map" do
    event = {:string, "raw event"}
    result = Filter.filter(event, [])
    assert result == event
  end

  test "filter/2 redacts all sensitive key types" do
    sensitive_meta = %{
      secret: "s1",
      private_key: "pk",
      preimage: "pi",
      blinding_factor: "bf",
      C: "c_val",
      C_: "c_prime",
      r: "r_val"
    }

    event = %{level: :debug, msg: {:string, "test"}, meta: sensitive_meta}
    result = Filter.filter(event, [])

    Enum.each([:secret, :private_key, :preimage, :blinding_factor, :C, :C_, :r], fn key ->
      assert result.meta[key] == "[REDACTED]"
    end)
  end
end
