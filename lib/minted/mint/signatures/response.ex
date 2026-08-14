defmodule Minted.Mint.Signatures.Response do
  @moduledoc """
  Wire-format value object for a blind signature returned by the mint.
  Carries the denomination amount, the signed blinded point C', and
  the keyset ID. Distinct from the `Minted.Mint.Signatures.Blind` adapter.
  """

  alias Minted.Mint.Token

  @enforce_keys [:amount, :c_prime, :keyset_id]
  defstruct [:amount, :c_prime, :keyset_id, :dleq]

  @type dleq :: %{e: binary(), s: binary()}

  @type t :: %__MODULE__{
          amount: pos_integer(),
          c_prime: binary(),
          keyset_id: String.t(),
          dleq: dleq() | nil
        }

  @spec valid?(t()) :: boolean()
  def valid?(%__MODULE__{amount: amount, c_prime: c_prime, keyset_id: keyset_id}) do
    Token.valid_denomination?(amount) and
      is_binary(c_prime) and byte_size(c_prime) == 33 and
      valid_point_prefix?(c_prime) and
      is_binary(keyset_id) and keyset_id != ""
  end

  def valid?(_), do: false

  # Compressed SEC1 point must start with 0x02 or 0x03
  defp valid_point_prefix?(<<prefix, _::binary-32>>) when prefix in [0x02, 0x03], do: true
  defp valid_point_prefix?(_), do: false
end
