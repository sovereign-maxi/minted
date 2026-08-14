defmodule Minted.Mint.Services.Redemption do
  @moduledoc """
  Handles token redemption (melt flow). Verifies signatures,
  checks the spent set, and atomically marks tokens as spent.
  All-or-nothing: partial redemptions are never allowed.
  """

  require Logger

  alias Minted.Events.EventBus
  alias Minted.Events.Mint, as: MintEvents
  alias Minted.Mint.{Keyset, Token}
  alias Minted.Mint.Spent
  alias Minted.Storage.Facade, as: StorageFacade

  @spec verify_batch([Token.t()], Keyset.t()) :: :ok | {:error, term()}
  def verify_batch(tokens, %Keyset{} = keyset) when is_list(tokens) do
    mismatched =
      Enum.with_index(tokens)
      |> Enum.reject(fn {t, _} -> t.keyset_id == keyset.id end)

    if mismatched != [] do
      {_token, idx} = hd(mismatched)
      {:error, {:keyset_mismatch, index: idx, expected: keyset.id}}
    else
      do_verify_batch(tokens, keyset)
    end
  end

  defp do_verify_batch(tokens, keyset) do
    Enum.reduce_while(Enum.with_index(tokens), :ok, fn {token, idx}, :ok ->
      case verify_and_check_spent(token, idx, keyset) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp verify_and_check_spent(token, idx, keyset) do
    case verify_token(token, keyset) do
      :ok ->
        if Spent.spent?(token.secret),
          do: {:error, {:already_spent, index: idx}},
          else: :ok

      {:error, reason} ->
        {:error, {reason, index: idx}}
    end
  end

  @spec redeem([Token.t()], Keyset.t()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def redeem([], _keyset), do: {:error, :empty_batch}

  def redeem(tokens, %Keyset{} = keyset) when is_list(tokens) do
    # Verify all tokens belong to the specified keyset
    mismatched =
      Enum.with_index(tokens)
      |> Enum.reject(fn {t, _i} -> t.keyset_id == keyset.id end)

    if mismatched != [] do
      {_token, idx} = hd(mismatched)
      {:error, {:keyset_mismatch, index: idx, expected: keyset.id}}
    else
      do_redeem(tokens, keyset)
    end
  end

  defp do_redeem(tokens, keyset) do
    indexed = Enum.with_index(tokens)
    entries = Enum.map(tokens, fn %Token{secret: secret} -> {secret, keyset.id} end)
    verify_fn = build_verify_fn(indexed, keyset)

    total = Enum.sum(Enum.map(tokens, & &1.amount))

    # Verify + mark spent FIRST — if any token is already spent or has
    # a bad signature, we do NOT want a :tokens_burned WAL entry hanging
    # around for tokens that never actually got burned. Contrast with
    # `commit_reservation/2` below which correctly writes WAL after the
    # verify_and_reserve → sign → commit sequence.
    with :ok <- Spent.verify_and_mark_spent(entries, verify_fn),
         :ok <- write_liability_wal(:tokens_burned, %{amount: total, keyset_id: keyset.id}) do
      :telemetry.execute(
        [:minted, :mint, :redeem],
        %{total_sats: total, count: length(tokens)},
        %{
          keyset_id: keyset.id
        }
      )

      EventBus.publish(%MintEvents.TokensBurned{
        amount: total,
        count: length(tokens),
        timestamp: DateTime.utc_now()
      })

      {:ok, total}
    end
  end

  @doc """
  Verifies token signatures and reserves them in the spent set without permanently
  marking them as spent. Tokens are blocked from re-use while reserved.
  """
  @spec verify_and_reserve([Token.t()], Keyset.t()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def verify_and_reserve([], _keyset), do: {:error, :empty_batch}

  def verify_and_reserve(tokens, %Keyset{} = keyset) when is_list(tokens) do
    mismatched =
      Enum.with_index(tokens)
      |> Enum.reject(fn {t, _i} -> t.keyset_id == keyset.id end)

    if mismatched != [] do
      {_token, idx} = hd(mismatched)
      {:error, {:keyset_mismatch, index: idx, expected: keyset.id}}
    else
      do_verify_and_reserve(tokens, keyset)
    end
  end

  defp do_verify_and_reserve(tokens, keyset) do
    indexed = Enum.with_index(tokens)
    entries = Enum.map(tokens, fn %Token{secret: secret} -> {secret, keyset.id} end)
    verify_fn = build_verify_fn(indexed, keyset)

    with :ok <- Spent.verify_and_reserve(entries, verify_fn) do
      total = Enum.sum(Enum.map(tokens, & &1.amount))
      {:ok, total}
    end
  end

  @doc """
  Commits a previous reservation, permanently marking tokens as spent.
  Call after Lightning payment succeeds.
  """
  @spec commit_reservation([Token.t()], Keyset.t()) :: :ok | {:error, term()}
  def commit_reservation(tokens, %Keyset{} = keyset) when is_list(tokens) do
    entries = Enum.map(tokens, fn %Token{secret: secret} -> {secret, keyset.id} end)
    total = Enum.sum(Enum.map(tokens, & &1.amount))

    # WAL BEFORE Spent.commit_reserved — same invariant as do_redeem/2.
    # A crash between Spent and WAL would leave proofs durably spent
    # without a matching :tokens_burned entry, undercounting burn and
    # over-stating outstanding liability on recovery.
    with :ok <- write_liability_wal(:tokens_burned, %{amount: total, keyset_id: keyset.id}),
         :ok <- Spent.commit_reserved(entries) do
      :telemetry.execute(
        [:minted, :mint, :redeem],
        %{total_sats: total, count: length(tokens)},
        %{keyset_id: keyset.id}
      )

      EventBus.publish(%MintEvents.TokensBurned{
        amount: total,
        count: length(tokens),
        timestamp: DateTime.utc_now()
      })

      :ok
    end
  end

  @doc """
  Releases a previous reservation, making tokens available again.
  Call when Lightning payment fails.
  """
  @spec release_reservation([Token.t()], Keyset.t()) :: :ok
  def release_reservation(tokens, %Keyset{} = keyset) when is_list(tokens) do
    entries = Enum.map(tokens, fn %Token{secret: secret} -> {secret, keyset.id} end)
    Spent.release_reserved(entries)
  end

  # Build a verify function that looks up a token by secret in the indexed list.
  # Returns {:error, :proof_not_found, -1} if no match found.
  defp build_verify_fn(indexed, keyset) do
    fn secret, _keyset_id ->
      indexed
      |> Enum.find(fn {t, _i} -> Plug.Crypto.secure_compare(t.secret, secret) end)
      |> verify_found_token(keyset)
    end
  end

  defp verify_found_token(nil, _keyset), do: {:error, :proof_not_found, -1}

  defp verify_found_token({token, index}, keyset) do
    case verify_token(token, keyset) do
      :ok -> :ok
      {:error, reason} -> {:error, reason, index}
    end
  end

  # Assumes pre-validated Token struct from Token.deserialize/1.
  # Callers must ensure tokens are deserialized before verification.
  defp verify_token(%Token{amount: amount, secret: secret, c: c}, keyset) do
    case Keyset.get_key(keyset, amount) do
      {:ok, {privkey, _pubkey}} ->
        Cashew.verify(privkey, secret, c)

      {:error, :denomination_not_found} ->
        {:error, :denomination_not_found}
    end
  end

  # WAL write for liability tracking — failures are surfaced to the caller.
  # WAL is written BEFORE EventBus.publish to guarantee durable record precedes broadcast.
  defp write_liability_wal(type, payload) do
    StorageFacade.write_wal(type, payload)
  rescue
    e ->
      Logger.error("Redemption: WAL write failed for #{type}: #{inspect(e)}")
      :telemetry.execute([:minted, :wal, :write_failure], %{count: 1}, %{type: type})
      {:error, :wal_write_failed}
  end
end
