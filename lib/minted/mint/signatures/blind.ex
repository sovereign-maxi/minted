defmodule Minted.Mint.Signatures.Blind do
  @moduledoc """
  Anti-corruption layer wrapping the raw NIF calls with domain types.

  This module translates between domain structs and the raw binary
  arguments expected by `Cashew`. Domain code should never call the
  NIF module directly — this adapter is the boundary between the
  crypto infrastructure and the mint domain.

  Implements the Blind Diffie-Hellman Key Exchange (BDHKE) protocol
  as specified by Cashu NUT-00.
  """

  defmodule KeyPair do
    @moduledoc """
    A secp256k1 keypair with 32-byte private key and 33-byte compressed public key.
    """
    @enforce_keys [:private_key, :public_key]
    defstruct [:private_key, :public_key]

    @type t :: %__MODULE__{
            private_key: <<_::256>>,
            public_key: <<_::264>>
          }
  end

  defmodule BlindedMessage do
    @moduledoc """
    A blinded message (B') ready to be signed by the mint.
    """
    @enforce_keys [:b_prime]
    defstruct [:b_prime, :blinding_factor, :secret]

    @type t :: %__MODULE__{
            b_prime: <<_::264>>,
            blinding_factor: <<_::256>>,
            secret: binary() | nil
          }
  end

  defmodule BlindSignature do
    @moduledoc """
    A blind signature (C') returned by the mint.
    """
    @enforce_keys [:c_prime]
    defstruct [:c_prime]

    @type t :: %__MODULE__{
            c_prime: <<_::264>>
          }
  end

  defmodule Proof do
    @moduledoc """
    An unblinded signature (C) that serves as proof of a valid token.
    """
    @enforce_keys [:secret, :c]
    defstruct [:secret, :c]

    @type t :: %__MODULE__{
            secret: binary(),
            c: <<_::264>>
          }
  end

  # --- Key Generation ---

  @doc """
  Generate a new random secp256k1 keypair.

  Returns `{:ok, %KeyPair{}}` with 32-byte private key and 33-byte
  compressed public key.
  """
  @spec generate_keypair() :: {:ok, KeyPair.t()}
  def generate_keypair do
    {:ok, {privkey, pubkey}} = Cashew.generate_keypair()
    {:ok, %KeyPair{private_key: privkey, public_key: pubkey}}
  end

  @doc """
  Derive the public key from a private key.

  Returns `{:ok, pubkey}` as a 33-byte compressed public key binary,
  or `{:error, reason}`.
  """
  @spec pubkey_from_privkey(binary()) :: {:ok, binary()} | {:error, atom()}
  def pubkey_from_privkey(private_key) when is_binary(private_key) do
    Cashew.pubkey_from_privkey(private_key)
  end

  # --- Hash to Curve ---

  @doc """
  Hash a secret to a secp256k1 curve point.

  Returns `{:ok, point}` where `point` is a 33-byte compressed public key.
  """
  @spec hash_to_curve(binary()) :: {:ok, binary()} | {:error, atom()}
  def hash_to_curve(secret) when is_binary(secret) do
    Cashew.hash_to_curve(secret)
  end

  # --- BDHKE Protocol ---

  @doc """
  Step 1 (Alice/client): Create a blinded message from a secret.

  Computes B' = Y + r*G where Y = hash_to_curve(secret).
  An optional blinding factor can be provided; otherwise one is generated.

  Returns `{:ok, %BlindedMessage{}}` containing the blinded point B',
  the blinding factor r, and the original secret.
  """
  @spec blind(binary(), binary() | nil) ::
          {:ok, BlindedMessage.t()} | {:error, atom()}
  def blind(secret, blinding_factor \\ nil) when is_binary(secret) do
    case Cashew.step1_alice(secret, blinding_factor) do
      {:ok, {b_prime, r}} ->
        {:ok,
         %BlindedMessage{
           b_prime: b_prime,
           blinding_factor: r,
           secret: secret
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Step 2 (Bob/mint): Sign a blinded message.

  Computes C' = k * B' where k is the mint's private key.

  Accepts a `%BlindedMessage{}` struct and a `%KeyPair{}` or raw private key binary.
  Returns `{:ok, %BlindSignature{}}` containing the blind signature C'.
  """
  @spec sign(BlindedMessage.t(), KeyPair.t() | binary()) ::
          {:ok, BlindSignature.t()} | {:error, atom()}
  def sign(%BlindedMessage{b_prime: b_prime}, %KeyPair{private_key: privkey}) do
    sign_raw(privkey, b_prime)
  end

  def sign(%BlindedMessage{b_prime: b_prime}, privkey) when is_binary(privkey) do
    sign_raw(privkey, b_prime)
  end

  defp sign_raw(privkey, b_prime) do
    case Cashew.step2_bob(privkey, b_prime) do
      {:ok, c_prime} ->
        {:ok, %BlindSignature{c_prime: c_prime}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Step 3 (Alice/client): Unblind the signature to obtain the proof.

  Computes C = C' - r*K where C' is the blind signature,
  r is the blinding factor, and K is the mint's public key.

  Returns `{:ok, %Proof{}}` containing the unblinded signature C and the secret.
  """
  @spec unblind(BlindSignature.t(), BlindedMessage.t(), binary()) ::
          {:ok, Proof.t()} | {:error, atom()}
  def unblind(
        %BlindSignature{c_prime: c_prime},
        %BlindedMessage{blinding_factor: r, secret: secret},
        mint_pubkey
      )
      when is_binary(mint_pubkey) do
    case Cashew.step3_alice(c_prime, r, mint_pubkey) do
      {:ok, c} ->
        {:ok, %Proof{secret: secret, c: c}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Verify that a proof (unblinded signature) is valid for a given secret
  under the specified mint private key.

  Returns `:ok` if valid, `{:error, :invalid_signature}` otherwise.
  """
  @spec verify(Proof.t(), KeyPair.t() | binary()) :: :ok | {:error, atom()}
  def verify(%Proof{secret: secret, c: c}, %KeyPair{private_key: privkey}) do
    Cashew.verify(privkey, secret, c)
  end

  def verify(%Proof{secret: secret, c: c}, privkey) when is_binary(privkey) do
    Cashew.verify(privkey, secret, c)
  end

  @doc """
  Perform the full BDHKE roundtrip: blind, sign, unblind, and return the proof.

  This is a convenience function primarily useful for testing.
  Returns `{:ok, %Proof{}}` or `{:error, reason}`.
  """
  @spec blind_sign_unblind(binary(), KeyPair.t()) ::
          {:ok, Proof.t()} | {:error, atom()}
  def blind_sign_unblind(secret, %KeyPair{} = keypair) when is_binary(secret) do
    with {:ok, blinded_msg} <- blind(secret),
         {:ok, blind_sig} <- sign(blinded_msg, keypair) do
      unblind(blind_sig, blinded_msg, keypair.public_key)
    end
  end
end
