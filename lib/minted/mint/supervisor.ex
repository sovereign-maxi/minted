defmodule Minted.Mint.Supervisor do
  @moduledoc false

  use Supervisor

  alias Minted.Storage.Facade, as: StorageFacade

  def start_link(init_arg) do
    Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    children = [
      # Holder owns Spent ETS tables so they survive Spent crashes.
      # Must start first — Spent expects tables to already exist.
      Minted.Mint.Holder,
      Minted.Mint.Spent,
      {Minted.Mint.Services.Quotes, dets_path: StorageFacade.mint_quotes_path()},
      {Minted.Mint.Pending, path: StorageFacade.mint_pending_path()},
      Minted.Mint.Pending.Reconciler,
      Minted.Mint.House.Store
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end
end
