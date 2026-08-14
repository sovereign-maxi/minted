defmodule Minted.Mint.Services.Signing do
  @moduledoc """
  Handles blind signing of blinded messages from paid quotes.

  Signs directly via `Cashew` NIF with the active keyset's private keys.
  """

  alias Minted.Mint.Keyset
  alias Minted.Mint.Signatures.{Message, Response}

  @max_batch_size 1000

  @spec sign([Message.t()], Keyset.t()) ::
          {:ok, [Response.t()]} | {:error, term()}
  def sign([], _keyset), do: {:ok, []}

  def sign(messages, _keyset) when length(messages) > @max_batch_size do
    {:error, :batch_too_large}
  end

  # Retired keysets still hold live private keys (see `Keyset.retire/1`);
  # only `:expired` keysets have had their material scrubbed. A user
  # whose deposit was pinned to a keyset that has since rotated must
  # still be able to claim their tokens against that pinned keyset —
  # rejecting `:retired` here would strand every paid-but-not-yet-
  # claimed quote across every rotation.
  def sign(_messages, %Keyset{status: :expired}) do
    {:error, :keyset_expired}
  end

  def sign(messages, %Keyset{status: status} = keyset)
      when status in [:active, :retired] and is_list(messages) do
    with :ok <- validate_blinded_messages(messages) do
      sign_validated(messages, keyset)
    end
  end

  def sign(_messages, %Keyset{}) do
    {:error, :keyset_not_active}
  end

  defp sign_validated(messages, keyset) do
    results =
      Enum.reduce_while(messages, {:ok, []}, fn %Message{} = msg, {:ok, acc} ->
        case sign_single(msg, keyset) do
          {:ok, blind_sig} -> {:cont, {:ok, [blind_sig | acc]}}
          {:error, _} = error -> {:halt, error}
        end
      end)

    case results do
      {:ok, sigs} ->
        :telemetry.execute([:minted, :mint, :sign], %{count: length(sigs)}, %{
          keyset_id: keyset.id
        })

        {:ok, Enum.reverse(sigs)}

      {:error, reason} = error ->
        :telemetry.execute([:minted, :mint, :sign_failed], %{count: 1}, %{
          keyset_id: keyset.id,
          reason: reason
        })

        error
    end
  end

  defp validate_blinded_messages(messages) do
    invalid =
      Enum.with_index(messages)
      |> Enum.reject(fn {msg, _i} -> Message.valid?(msg) end)

    case invalid do
      [] -> :ok
      [{_msg, i} | _] -> {:error, {:invalid_blinded_message, index: i}}
    end
  end

  defp sign_single(%Message{amount: amount, b_prime: b_prime}, %Keyset{} = keyset) do
    case Keyset.get_key(keyset, amount) do
      {:ok, {privkey, _pubkey}} ->
        case Cashew.step2_bob(privkey, b_prime) do
          {:ok, c_prime} ->
            dleq = generate_dleq(privkey, b_prime)

            {:ok,
             %Response{
               amount: amount,
               c_prime: c_prime,
               keyset_id: keyset.id,
               dleq: dleq
             }}

          error ->
            error
        end

      {:error, :denomination_not_found} ->
        {:error, :denomination_not_found}
    end
  end

  # Generate NUT-12 DLEQ proof for the blind signature.
  # Returns %{e: binary, s: binary} on success, nil on failure (non-fatal).
  defp generate_dleq(privkey, b_prime) do
    case Cashew.generate_dleq_proof(privkey, b_prime) do
      {:ok, {e, s}} -> %{e: e, s: s}
      {:error, _} -> nil
    end
  end
end
