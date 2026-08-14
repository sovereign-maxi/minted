defmodule Minted.Reserves.Source do
  @moduledoc false
  @behaviour Vault.Source

  alias Minted.Lightning.Facade, as: LightningFacade
  alias Minted.Mint.Facade, as: MintFacade
  alias Minted.Reserves.Trackers.Liability
  alias Minted.Storage.Facade, as: StorageFacade

  @impl Vault.Source
  def reserves do
    {balance, _status} = LightningFacade.liquidity_status()
    %{total_held: balance}
  rescue
    _ -> %{total_held: 0}
  end

  @impl Vault.Source
  def liabilities do
    liability = Liability.current()
    pending = pending_quote_liability()

    %{
      issued: liability.minted + pending,
      redeemed: liability.burned,
      outstanding: liability.outstanding + pending
    }
  end

  # A mint quote in `:paid` status (Lightning settled, tokens not yet
  # signed at /v1/mint) is a latent claim — the operator received the
  # sats and owes tokens. Until the user posts to /v1/mint, the
  # liability counter (which sums `TokensMinted` events) does not
  # reflect this. Without it, a snapshot taken in that window over-
  # states solvency. Sum the `amount` of every quote that is paid but
  # not yet redeemed.
  defp pending_quote_liability do
    MintFacade.find_active_mint_quotes()
    |> Enum.filter(&(&1.status == :paid))
    |> Enum.reduce(0, fn q, acc -> acc + q.amount end)
  rescue
    _ -> 0
  end

  @impl Vault.Source
  def asset_ids do
    StorageFacade.get_active_keyset()
    |> Enum.map(fn
      %{id: id} -> id
      _ -> nil
    end)
    |> Enum.reject(&is_nil/1)
  rescue
    _ -> []
  end

  @impl Vault.Source
  def metadata do
    %{
      epoch_id: 0,
      state_root: nil,
      spent_count: safe_call(fn -> MintFacade.spent_count() end, 0)
    }
  end

  defp safe_call(fun, default) do
    fun.()
  rescue
    _ -> default
  end
end
