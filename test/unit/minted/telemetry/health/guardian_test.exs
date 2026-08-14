defmodule Minted.Telemetry.Health.PeerTest do
  @moduledoc "Unit tests for Minted.Telemetry.Health.Peer."

  use ExUnit.Case, async: true

  alias Minted.Telemetry.Health.Peer

  test "score/1 returns 1.0 in single-node stub mode" do
    assert Peer.score("peer-1") == 1.0
    assert Peer.score("any-id") == 1.0
  end

  test "all_scores/0 returns empty map in single-node stub mode" do
    assert Peer.all_scores() == %{}
  end

  test "sub_scores/1 returns all perfect in single-node stub mode" do
    scores = Peer.sub_scores("peer-1")
    assert scores.heartbeat == 1.0
    assert scores.consensus == 1.0
    assert scores.signing == 1.0
    assert scores.latency == 1.0
  end

  test "compute/1 with perfect scores returns 1.0" do
    scores = %{heartbeat: 1.0, consensus: 1.0, signing: 1.0, latency: 1.0}
    assert Peer.compute(scores) == 1.0
  end

  test "compute/1 with zero scores returns 0.0" do
    scores = %{heartbeat: 0.0, consensus: 0.0, signing: 0.0, latency: 0.0}
    assert Peer.compute(scores) == 0.0
  end

  test "compute/1 with mixed scores returns weighted average" do
    scores = %{heartbeat: 1.0, consensus: 0.5, signing: 0.0, latency: 0.0}
    # 1.0 * 0.3 + 0.5 * 0.3 + 0.0 * 0.2 + 0.0 * 0.2 = 0.45
    assert Peer.compute(scores) == 0.45
  end

  test "compute/1 clamps to 0.0-1.0 range" do
    high = %{heartbeat: 2.0, consensus: 2.0, signing: 2.0, latency: 2.0}
    assert Peer.compute(high) == 1.0

    low = %{heartbeat: -1.0, consensus: -1.0, signing: -1.0, latency: -1.0}
    assert Peer.compute(low) == 0.0
  end
end
