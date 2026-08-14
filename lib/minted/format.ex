defmodule Minted.Format do
  @moduledoc false

  @doc """
  Formats an integer amount with comma-separated thousands.

  Returns the raw formatted string without any unit suffix.

  ## Examples

      iex> Minted.Format.format_sats(1500)
      "1,500"

      iex> Minted.Format.format_sats(42)
      "42"

      iex> Minted.Format.format_sats(1_000_000)
      "1,000,000"

  """
  @spec format_sats(integer() | float() | binary() | nil) :: String.t()
  def format_sats(amount) when is_integer(amount) and amount < 0 do
    "-" <> comma_separate(Integer.to_string(-amount))
  end

  def format_sats(amount) when is_integer(amount) do
    amount
    |> Integer.to_string()
    |> comma_separate()
  end

  def format_sats(amount) when is_float(amount), do: format_sats(round(amount))

  def format_sats(amount) when is_binary(amount) do
    case Integer.parse(amount) do
      {int, _} -> format_sats(int)
      :error -> amount
    end
  end

  def format_sats(_), do: "0"

  @doc "Returns a truncated keyset ID for display (first 8 chars)."
  @spec short_keyset_id(String.t() | nil) :: String.t()
  def short_keyset_id(nil), do: "—"
  def short_keyset_id(id) when byte_size(id) > 8, do: binary_part(id, 0, 8)
  def short_keyset_id(id), do: id

  defp comma_separate(str) do
    str
    |> String.reverse()
    |> String.to_charlist()
    |> Enum.chunk_every(3)
    |> Enum.join(",")
    |> String.reverse()
  end
end
