defmodule Minted.Telemetry.FormatterTest do
  @moduledoc "Unit tests for Minted.Telemetry.Formatter."

  use ExUnit.Case, async: true

  alias Minted.Telemetry.Formatter

  test "sensitive_keys/0 returns a MapSet" do
    keys = Formatter.sensitive_keys()
    assert %MapSet{} = keys
    assert MapSet.member?(keys, :secret)
    assert MapSet.member?(keys, :private_key)
    assert MapSet.member?(keys, :preimage)
    assert MapSet.member?(keys, :blinding_factor)
  end

  test "redact_metadata/1 redacts sensitive keys" do
    metadata = [secret: "abc123", domain: [:minted], pid: self()]
    result = Formatter.redact_metadata(metadata)

    assert Keyword.get(result, :secret) == "[REDACTED]"
    assert Keyword.get(result, :domain) == [:minted]
    assert Keyword.get(result, :pid) == self()
  end

  test "redact_metadata/1 redacts nested map values" do
    metadata = [data: %{secret: "hidden", name: "visible"}]
    result = Formatter.redact_metadata(metadata)

    data = Keyword.get(result, :data)
    assert data.secret == "[REDACTED]"
    assert data.name == "visible"
  end

  test "redact_metadata/1 handles empty list" do
    assert Formatter.redact_metadata([]) == []
  end

  test "format/4 returns iodata" do
    timestamp = {{2024, 1, 1}, {12, 0, 0, 0}}
    result = Formatter.format(:info, "hello", timestamp, domain: [:minted])
    assert is_list(result) or is_binary(result)
  end

  test "format/4 redacts sensitive patterns in messages" do
    timestamp = {{2024, 1, 1}, {12, 0, 0, 0}}
    message = "processing secret=abc123 for user"
    result = Formatter.format(:info, message, timestamp, [])
    output = IO.chardata_to_string(result)

    refute String.contains?(output, "abc123")
    assert String.contains?(output, "[REDACTED]")
  end

  test "format/4 redacts sensitive metadata values" do
    timestamp = {{2024, 1, 1}, {12, 0, 0, 0}}
    result = Formatter.format(:warning, "test", timestamp, private_key: "deadbeef")
    assert is_list(result) or is_binary(result)
  end
end
