defmodule Minted.Mint.Facade do
  @moduledoc """
  Published Language facade for the Mint bounded context.

  This is the only legal cross-domain entry point for Mint functionality.
  State-mutating operations (sign, swap, spend) use direct BDHKE signing.

  Returns plain maps/tuples, never domain-internal structs.
  """

  alias Minted.Guards

  alias Minted.Mint.{Fees, Keyset, Token}
  alias Minted.Mint.Services.{Quotes, Redemption, Signing, Swap}
  alias Minted.Mint.Signatures.Blind
  alias Minted.Mint.Spent
  alias Minted.Storage.Facade, as: StorageFacade

  alias Minted.Events.EventBus
  alias Minted.Events.Mint, as: MintEvents

  require Logger

  # --- Keyset ---

  @doc "Generates a new keyset, returning a plain map."
  @spec generate_keyset() :: map()
  def generate_keyset do
    keyset = Keyset.generate()
    Map.from_struct(keyset)
  end

  @doc "Converts a store map to a keyset struct result."
  @spec keyset_from_store_map(map()) :: {:ok, map()} | {:error, term()}
  def keyset_from_store_map(store_map) do
    Keyset.from_store_map(store_map)
  end

  @doc "Gets a key pair for a denomination from a keyset."
  @spec get_keyset_key(map() | struct(), non_neg_integer()) ::
          {:ok, {binary(), binary()}} | {:error, term()}
  def get_keyset_key(keyset, denomination) do
    Keyset.get_key(keyset, denomination)
  end

  # Keys are pre-generated offline or auto-generated at first boot.

  @doc "Returns the active keyset ID, or nil if no keyset is active."
  @spec active_keyset_id() :: String.t() | nil
  def active_keyset_id do
    case StorageFacade.get_active_keyset() do
      [%{id: id} | _] -> id
      _ -> nil
    end
  end

  # --- Signing ---

  @doc """
  Signs blinded messages with the caller-supplied keyset and publishes
  TokensMinted event.

  The keyset is the one the caller resolved (typically the quote's pinned
  keyset via `get_keyset_for_quote/1`) — this function does NOT re-read
  the active keyset. Signing with a different keyset than the caller
  passed produces DLEQ mismatches on the client and is the bug this
  contract prevents.

  Use `publish_event: false` for swap callers to avoid double-count.
  """
  @spec sign(list(), map() | struct(), keyword()) :: {:ok, list()} | {:error, term()}
  def sign(blinded_messages, keyset, opts \\ []) do
    Guards.ensure_operational!()

    result =
      with {:ok, ks} <- ensure_keyset_struct(keyset) do
        Signing.sign(blinded_messages, ks)
      end

    with {:ok, signatures} <- result do
      unless Keyword.get(opts, :publish_event) == false do
        total = Enum.sum(Enum.map(blinded_messages, & &1.amount))

        EventBus.publish(%MintEvents.TokensMinted{
          amount: total,
          count: length(blinded_messages),
          timestamp: DateTime.utc_now()
        })
      end

      {:ok, signatures}
    end
  end

  # --- Swap ---

  @doc """
  Atomic token swap: spend old tokens, sign new blinded messages.

  Delegates to `Services.Swap` which handles reservation, signing,
  and commit atomically.
  """
  @spec swap(list(), list(), map() | struct(), map() | struct()) ::
          {:ok, list()} | {:error, term()}
  def swap(tokens, blinded_messages, input_keyset, active_keyset) do
    Guards.ensure_operational!()

    input_ks = ensure_keyset_struct(input_keyset)
    output_ks = ensure_keyset_struct(active_keyset)

    case {input_ks, output_ks} do
      {{:ok, iks}, {:ok, oks}} ->
        Swap.swap(tokens, blinded_messages, iks, oks)

      {{:error, _} = err, _} ->
        err

      {_, {:error, _} = err} ->
        err
    end
  end

  defp ensure_keyset_struct(%Keyset{} = ks), do: {:ok, ks}

  defp ensure_keyset_struct(%{} = map) do
    Keyset.from_store_map(map)
  end

  # --- Redemption ---

  @doc "Verifies tokens and reserves them for spending."
  @spec verify_and_reserve(list(), map() | struct()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def verify_and_reserve(tokens, keyset) do
    Guards.ensure_operational!()
    Redemption.verify_and_reserve(tokens, keyset)
  end

  @doc "Commits a previously reserved token set."
  @spec commit_reservation(list(), map() | struct()) :: :ok | {:error, term()}
  def commit_reservation(tokens, keyset) do
    Guards.ensure_operational!()
    Redemption.commit_reservation(tokens, keyset)
  end

  @doc "Releases a previously reserved token set."
  @spec release_reservation(list(), map() | struct()) :: :ok
  def release_reservation(tokens, keyset),
    do: Redemption.release_reservation(tokens, keyset)

  # --- Spent ---

  @doc "Returns true if the secret has been spent."
  @spec spent?(binary()) :: boolean()
  def spent?(secret), do: Spent.spent?(secret)

  @doc """
  Returns true if the Y point (NUT-07 identifier) has been spent. Used by
  the /v1/check endpoint to answer proof state queries.
  """
  @spec spent_by_y?(binary()) :: boolean()
  def spent_by_y?(y_bytes), do: Spent.spent_by_y?(y_bytes)

  @doc "Returns the total number of spent tokens."
  @spec spent_count() :: non_neg_integer()
  def spent_count, do: Spent.count()

  @doc "Marks a token secret as spent."
  @spec mark_spent(binary(), binary()) :: :ok | {:error, term()}
  def mark_spent(secret, keyset_id) do
    Guards.ensure_operational!()
    Spent.mark_spent(secret, keyset_id)
  end

  @doc "Compacts the spent set for a keyset."
  @spec compact_keyset(binary()) :: {:ok, map()} | {:error, term()}
  def compact_keyset(keyset_id), do: Spent.compact_keyset(keyset_id)

  # --- Fees ---

  @doc "Calculates the deposit fee for the given amount in sats."
  @spec deposit_fee(non_neg_integer()) :: non_neg_integer()
  def deposit_fee(amount_sats) when is_integer(amount_sats) and amount_sats >= 0 do
    schedule = Fees.from_config()
    {:ok, fee} = Fees.calculate(schedule, amount_sats, :deposit)
    fee
  end

  @doc "Estimates the withdrawal fee (routing cost passed through to user)."
  @spec withdrawal_fee(non_neg_integer()) :: non_neg_integer()
  def withdrawal_fee(amount_sats) when is_integer(amount_sats) and amount_sats >= 0 do
    Minted.Lightning.Facade.routing_fee_estimate(amount_sats)
  end

  # --- Quotes ---

  @doc "Retrieves a quote by ID."
  @spec get_quote(String.t()) :: {:ok, map()} | {:error, term()}
  def get_quote(quote_id), do: Quotes.get_quote(quote_id)

  @doc "Returns all quotes with the given status."
  @spec list_quotes_by_status(atom()) :: [map()]
  def list_quotes_by_status(status), do: Quotes.list_by_status(status)

  @doc "Updates a quote with the given function."
  @spec update_quote(String.t(), function()) :: {:ok, map()} | {:error, term()}
  def update_quote(quote_id, update_fn), do: Quotes.update_quote(quote_id, update_fn)

  @doc """
  Creates a new mint (deposit) quote for the given amount.

  `owner_session` binds the quote to a browser wallet session so restore,
  claim, and cancel handlers can enforce ownership. `nil` is accepted for
  the `/v1` API path where the PoW gate governs owner semantics.
  """
  @spec create_mint_quote(pos_integer(), String.t() | nil) :: {:ok, map()} | {:error, term()}
  def create_mint_quote(amount, owner_session \\ nil) do
    Guards.ensure_operational!()
    Quotes.create_quote(amount, owner_session)
  end

  @doc """
  Creates a new melt (withdrawal) quote for the given amount and bolt11.
  See `create_mint_quote/2` for the `owner_session` semantics.
  """
  @spec create_melt_quote(non_neg_integer(), String.t(), String.t() | nil) ::
          {:ok, map()} | {:error, term()}
  def create_melt_quote(amount, bolt11, owner_session \\ nil) do
    Guards.ensure_operational!()
    Quotes.create_melt_quote(amount, bolt11, owner_session)
  end

  @doc """
  Returns the most recent active mint quote, or nil. Used by the wallet
  LiveView and the deposit panel to resume an in-flight deposit when the
  user refreshes the page.
  """
  @spec find_active_mint_quote() :: map() | nil
  def find_active_mint_quote, do: Quotes.find_active_deposit()

  @doc """
  Returns all active mint quotes — GLOBAL fold across every session.
  Used by the reserves accounting path (`Minted.Reserves.Source`) to
  sum pending liability. NEVER use this from user-facing surfaces —
  browser wallet flows must call `find_active_mint_quotes_for_owner/1`.
  """
  @spec find_active_mint_quotes() :: [map()]
  def find_active_mint_quotes, do: Quotes.find_active_deposits()

  @doc """
  Owner-scoped variant of `find_active_mint_quotes/0`. Filters to quotes
  whose `owner_session` matches the supplied token. Browser wallet
  LiveViews call this so one visitor cannot see (or claim) another
  visitor's paid deposit. `nil` / empty token returns `[]`.
  """
  @spec find_active_mint_quotes_for_owner(String.t() | nil) :: [map()]
  def find_active_mint_quotes_for_owner(owner_session),
    do: Quotes.find_active_deposits_for_owner(owner_session)

  # --- Redemption (additional) ---

  @doc "Delegates to the underlying service."
  @spec verify_batch(list(), map() | struct()) :: :ok | {:error, term()}
  def verify_batch(tokens, keyset), do: Redemption.verify_batch(tokens, keyset)

  @doc "Delegates to the underlying service."
  @spec redeem(list(), map() | struct()) :: {:ok, non_neg_integer()} | {:error, term()}
  def redeem(tokens, keyset), do: Redemption.redeem(tokens, keyset)

  # --- Signatures ---

  @doc "Delegates to the underlying service."
  @spec blind(binary()) :: {:ok, map()} | {:error, term()}
  def blind(secret), do: Blind.blind(secret)

  @doc "Delegates to the underlying service."
  @spec unblind(map() | struct(), map() | struct(), binary()) :: {:ok, map()} | {:error, term()}
  def unblind(blind_sig, blinded_msg, pubkey),
    do: Blind.unblind(blind_sig, blinded_msg, pubkey)

  # --- Token ---

  @doc "Delegates to the underlying service."
  @spec serialize_token(list()) :: {:ok, String.t()} | {:error, term()}
  def serialize_token(tokens), do: Token.serialize(tokens)

  @doc "Delegates to the underlying service."
  @spec deserialize_token(String.t()) :: {:ok, list()} | {:error, term()}
  def deserialize_token(cashu_string), do: Token.deserialize(cashu_string)

  # --- Observability helpers ---

  @doc """
  Returns the total memory footprint (bytes) of the spent-set ETS
  tables — main index, Y-index, and pending reservations. Used by the
  telemetry alerts manager without reaching into Mint internals.
  """
  @spec spent_set_memory_bytes() :: non_neg_integer()
  def spent_set_memory_bytes do
    word_size = :erlang.system_info(:wordsize)
    tables = [Spent, Spent.Y, Spent.Pending]

    Enum.sum(
      for t <- tables, :ets.whereis(t) != :undefined do
        :ets.info(t, :memory) * word_size
      end
    )
  end

  @doc """
  Returns the oldest `claimed_at`/`paying_since` timestamp for a quote
  currently in the given status, or nil if none exists. Used by the
  alerts manager to detect quotes stuck in `:settlement_unknown`.
  """
  @spec oldest_quote_in_status(atom()) :: DateTime.t() | nil
  def oldest_quote_in_status(status) when is_atom(status) do
    Quotes.oldest_in_status(status)
  end
end
