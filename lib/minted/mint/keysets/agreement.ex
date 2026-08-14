defmodule Minted.Mint.Keysets.Agreement do
  @moduledoc """
  Keyset agreement check. In single-node mode, always passes — there are
  no peers to disagree with.
  """

  @doc "Verifies keyset agreement. Always succeeds in single-node mode."
  @spec verify(binary()) :: :ok
  def verify(_keyset_id), do: :ok
end
