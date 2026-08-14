defmodule Minted.Reserves.Publishers.Event do
  @moduledoc """
  Vault.Publisher that broadcasts ProofGenerated events to PubSub.

  Bridges Vault's proof cycle to MINTED's event-driven UI updates.
  """

  @behaviour Vault.Publisher

  alias Minted.Events.EventBus
  alias Minted.Events.Reserves, as: ReservesEvents

  @impl Vault.Publisher
  def publish(%Vault.Proof{} = proof) do
    EventBus.publish(%ReservesEvents.ProofGenerated{
      proof_id: proof.id,
      status: proof.status,
      ratio: proof.snapshot.reserve_ratio,
      timestamp: proof.snapshot.captured_at
    })

    {:ok, proof.id}
  catch
    :exit, _reason -> {:ok, proof.id}
  end
end
