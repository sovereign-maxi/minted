defmodule Minted.Mint.Holder do
  @moduledoc false

  # Long-lived GenServer that owns ETS tables for the Mint context.
  # Prevents table destruction when Spent or Quotes crash —
  # the ETS tables survive because they are owned by this process,
  # which sits above the volatile GenServers in the supervision tree.
  #
  # Security note: Tables are `:public` because worker GenServers (Spent,
  # Quotes) need to write to tables owned by this holder process.
  # ETS access levels are not a security boundary in the BEAM — any process
  # on the same node can read/write `:public` tables. Access control is
  # enforced at the application API layer, not the ETS layer.

  use GenServer

  @tables [
    {Minted.Mint.Spent, [:set, :named_table, :public, read_concurrency: true]},
    {Minted.Mint.Spent.Y, [:set, :named_table, :public, read_concurrency: true]},
    {Minted.Mint.Spent.Pending, [:set, :named_table, :public, read_concurrency: true]}
  ]

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    for {name, table_opts} <- @tables do
      if :ets.whereis(name) == :undefined do
        :ets.new(name, table_opts)
      end
    end

    {:ok, :ok}
  rescue
    ArgumentError -> {:ok, :ok}
  end

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}
end
