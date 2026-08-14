defmodule Minted.Oracle.Facade do
  @moduledoc """
  Published Language facade for the Oracle bounded context.

  The oracle domain is a BTC/USD price feed used only for display
  purposes in the wallet UI. No pricing decisions depend on it. This
  facade is the single entry point for all cross-domain access to
  oracle state.
  """

  alias Minted.Oracle.Feed

  @doc """
  Returns the current BTC/USD price snapshot as `{price, updated_at}`
  where `price` is a float representing USD per BTC and `updated_at`
  is the `DateTime` of the last successful fetch. Either field can be
  `nil` if the feed has never published a price (or is currently
  unavailable), and callers must handle that case.
  """
  @spec current_price() :: {float() | nil, DateTime.t() | nil}
  def current_price do
    Feed.get_price()
  rescue
    _ -> {nil, nil}
  catch
    :exit, _ -> {nil, nil}
  end
end
