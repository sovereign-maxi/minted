defmodule Minted.Mint.Signatures.Message do
  @moduledoc """
  Wire-format value object for a blinded message sent by the client
  during the BDHKE protocol. Carries the denomination amount and
  the blinded point B'.
  """

  alias Minted.Mint.Token

  @enforce_keys [:amount, :b_prime]
  defstruct [:amount, :b_prime]

  @type t :: %__MODULE__{
          amount: pos_integer(),
          b_prime: binary()
        }

  @spec valid?(t()) :: boolean()
  def valid?(%__MODULE__{amount: amount, b_prime: b_prime}) do
    Token.valid_denomination?(amount) and
      is_binary(b_prime) and byte_size(b_prime) == 33 and
      valid_point_prefix?(b_prime)
  end

  def valid?(_), do: false

  # Compressed SEC1 point must start with 0x02 or 0x03
  # Point structure is validated downstream by Cashew.step2_bob/2
  # which returns {:error, :invalid_point} for malformed b_prime.
  defp valid_point_prefix?(<<prefix, _::binary-32>>) when prefix in [0x02, 0x03], do: true
  defp valid_point_prefix?(_), do: false
end
