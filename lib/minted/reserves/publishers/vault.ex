defmodule Minted.Reserves.Publishers.Vault do
  @moduledoc false
  @behaviour Vault.Publisher

  alias Minted.Reserves.Publishers.Nostr

  @impl Vault.Publisher
  def publish(%Vault.Proof{} = proof) do
    Nostr.publish_vault_proof(proof)
  end
end
