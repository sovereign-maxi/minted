defmodule Minted.Lightning.Adapters.WAL do
  @moduledoc """
  Implements `FireBird.WAL` by delegating to `Minted.Storage.WAL`.

  Wraps the payment data into a `Minted.Storage.WAL.Entry` with
  `type: :payments_in_flight` before appending.
  """

  @behaviour FireBird.WAL

  alias Minted.Storage.Facade, as: StorageFacade

  @impl FireBird.WAL
  def append(_config, payment_data) do
    StorageFacade.write_wal(:payments_in_flight, %{
      payments: List.wrap(payment_data),
      shutdown_at: System.system_time(:millisecond)
    })
  end

  @impl FireBird.WAL
  def recover(_config) do
    case StorageFacade.read_all_wal() do
      {:ok, entries} ->
        payments =
          entries
          |> Enum.filter(&(&1.type == :payments_in_flight))
          |> Enum.flat_map(fn entry -> Map.get(entry.payload, :payments, []) end)

        {:ok, payments}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
