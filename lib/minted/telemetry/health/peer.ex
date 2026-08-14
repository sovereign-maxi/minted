defmodule Minted.Telemetry.Health.Peer do
  @moduledoc false

  @heartbeat_weight 0.3
  @consensus_weight 0.3
  @signing_weight 0.2
  @latency_weight 0.2

  @type sub_scores :: %{
          heartbeat: float(),
          consensus: float(),
          signing: float(),
          latency: float()
        }

  @doc "Returns the composite health score for a peer (0.0 to 1.0)."
  @spec score(binary()) :: float()
  def score(_peer_id) do
    # Single-node stub — always healthy.
    1.0
  end

  @doc "Returns all peer scores as a map of peer_id to score."
  @spec all_scores() :: %{binary() => float()}
  def all_scores do
    # Single-node stub — no federation peers.
    %{}
  end

  @doc "Returns the sub-score breakdown for a peer."
  @spec sub_scores(binary()) :: sub_scores()
  def sub_scores(_peer_id) do
    # Single-node stub — all perfect.
    %{heartbeat: 1.0, consensus: 1.0, signing: 1.0, latency: 1.0}
  end

  @doc "Computes composite score from sub-scores."
  @spec compute(sub_scores()) :: float()
  def compute(scores) do
    raw =
      scores.heartbeat * @heartbeat_weight +
        scores.consensus * @consensus_weight +
        scores.signing * @signing_weight +
        scores.latency * @latency_weight

    Float.round(clamp(raw, 0.0, 1.0), 3)
  end

  defp clamp(value, min, max) do
    value |> Kernel.max(min) |> Kernel.min(max)
  end
end
