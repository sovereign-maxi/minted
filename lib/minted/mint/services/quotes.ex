defmodule Minted.Mint.Services.Quotes do
  @moduledoc """
  GenServer managing quote creation, storage, lifecycle tracking,
  and TTL-based cleanup. Entry point for the deposit (mint) flow.
  """

  use GenServer

  require Logger

  alias Minted.Events.EventBus
  alias Minted.Events.Lightning, as: LightningEvents
  alias Minted.Events.Mint, as: MintEvents
  alias Minted.Lightning.Facade, as: LightningFacade
  alias Minted.Mint.{Fees, Quote}
  alias Minted.Storage.Facade, as: StorageFacade

  @table Minted.Mint.Services.Quotes
  @durable Minted.Mint.Services.Quotes.Durable
  @cleanup_interval_ms 30_000
  @retry_mark_paid_delay_ms 500
  @max_mark_paid_retries 5
  @default_stale_claim_timeout_ms 120_000
  @default_max_deposit_sats 33_000_000
  @default_max_melt_sats 33_000_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec create_quote(pos_integer(), String.t() | nil) :: {:ok, Quote.t()} | {:error, term()}
  def create_quote(amount, owner_session \\ nil) when is_integer(amount) and amount > 0 do
    max = Application.get_env(:minted, :max_deposit_sats, @default_max_deposit_sats)

    if amount > max do
      {:error, :amount_too_large}
    else
      GenServer.call(__MODULE__, {:create_quote, amount, owner_session})
    end
  end

  @spec create_melt_quote(pos_integer(), String.t(), String.t() | nil) ::
          {:ok, Quote.t()} | {:error, term()}
  def create_melt_quote(amount, bolt11, owner_session \\ nil)
      when is_integer(amount) and amount > 0 and is_binary(bolt11) do
    GenServer.call(__MODULE__, {:create_melt_quote, amount, bolt11, owner_session})
  end

  @doc """
  Clears all quotes from the ETS table. Intended for use in tests.
  """
  @spec clear() :: :ok
  def clear, do: GenServer.call(__MODULE__, :clear)

  @doc """
  Inserts a pre-built quote. Intended for use in tests and recovery paths.
  """
  @spec store_quote(Quote.t()) :: :ok
  def store_quote(%Quote{} = quote) do
    GenServer.call(__MODULE__, {:store_quote, quote})
  end

  @spec get_quote(String.t()) :: {:ok, Quote.t()} | {:error, :not_found}
  def get_quote(id) when is_binary(id) do
    case :ets.lookup(@table, id) do
      [{^id, quote}] -> {:ok, quote}
      [] -> {:error, :not_found}
    end
  end

  @spec list_by_status(Quote.status()) :: [Quote.t()]
  def list_by_status(status) when is_atom(status) do
    :ets.foldl(
      fn {_id, quote}, acc ->
        if quote.status == status, do: [quote | acc], else: acc
      end,
      [],
      @table
    )
  rescue
    _ -> []
  end

  @doc """
  Returns the most recent active mint quote (`:invoiced` or `:paid`, non-expired,
  with an invoice attached). Used to restore modal state after LiveView reconnects.
  """
  @spec find_active_deposit() :: Quote.t() | nil
  def find_active_deposit do
    now = DateTime.utc_now()

    :ets.foldl(
      fn {_id, quote}, acc -> pick_newer_active(quote, acc, now) end,
      nil,
      @table
    )
  rescue
    _ -> nil
  end

  defp pick_newer_active(quote, acc, now) do
    if active_mint_quote?(quote, now) do
      if acc == nil or DateTime.compare(quote.created_at, acc.created_at) == :gt,
        do: quote,
        else: acc
    else
      acc
    end
  end

  @doc """
  Returns all active mint quotes (`:invoiced` or `:paid`, non-expired,
  with an invoice attached). Used to restore in-flight deposits after
  LiveView reconnects.
  """
  @spec find_active_deposits() :: [Quote.t()]
  def find_active_deposits do
    now = DateTime.utc_now()

    :ets.foldl(
      fn {_id, quote}, acc ->
        if active_mint_quote?(quote, now), do: [quote | acc], else: acc
      end,
      [],
      @table
    )
    |> Enum.sort_by(& &1.created_at, {:desc, DateTime})
  rescue
    _ -> []
  end

  @doc """
  Owner-scoped variant of `find_active_deposits/0`. Only returns quotes
  whose `owner_session` matches the supplied token — the browser wallet
  LiveView calls this so one visitor cannot see (or claim) another
  visitor's paid deposit. A `nil` or empty token returns `[]` — no quote
  is ever attributable to an anonymous session.
  """
  @spec find_active_deposits_for_owner(String.t() | nil) :: [Quote.t()]
  def find_active_deposits_for_owner(owner_session)
      when is_binary(owner_session) and owner_session != "" do
    now = DateTime.utc_now()

    :ets.foldl(
      fn {_id, quote}, acc ->
        if active_mint_quote?(quote, now) and quote.owner_session == owner_session do
          [quote | acc]
        else
          acc
        end
      end,
      [],
      @table
    )
    |> Enum.sort_by(& &1.created_at, {:desc, DateTime})
  rescue
    _ -> []
  end

  def find_active_deposits_for_owner(_), do: []

  defp active_mint_quote?(quote, now) do
    quote.type == :mint and
      quote.status in [:invoiced, :paid] and
      quote.invoice != nil and
      DateTime.compare(now, quote.expires_at) != :gt
  end

  @spec update_quote(String.t(), (Quote.t() -> {:ok, Quote.t()} | {:error, term()})) ::
          {:ok, Quote.t()} | {:error, term()}
  def update_quote(id, transition_fn) when is_binary(id) and is_function(transition_fn, 1) do
    GenServer.call(__MODULE__, {:update_quote, id, transition_fn})
  end

  @doc """
  Returns the oldest `claimed_at`/`paying_since` timestamp among quotes in
  the given status, or `nil` if none exist. Used by the alert pipeline to
  detect quotes stuck in a terminal-adjacent state for too long.
  """
  @spec oldest_in_status(Quote.status()) :: DateTime.t() | nil
  def oldest_in_status(status) when is_atom(status) do
    @table
    |> :ets.tab2list()
    |> Enum.reduce(nil, fn
      {_id, %Quote{status: ^status} = quote}, acc ->
        stamp = quote.paying_since || quote.claimed_at || quote.created_at

        cond do
          is_nil(stamp) -> acc
          is_nil(acc) -> stamp
          DateTime.compare(stamp, acc) == :lt -> stamp
          true -> acc
        end

      _other, acc ->
        acc
    end)
  end

  def oldest_in_status(_), do: nil

  # Server

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    table = :ets.new(@table, [:set, :named_table, :protected, read_concurrency: true])

    dets_path = Keyword.fetch!(opts, :dets_path) |> String.to_charlist()
    File.mkdir_p!(Path.dirname(dets_path))
    {:ok, _} = :dets.open_file(@durable, file: dets_path, type: :set)

    :dets.foldl(
      fn {id, quote}, _acc ->
        :ets.insert(@table, {id, quote})
      end,
      :ok,
      @durable
    )

    EventBus.subscribe(LightningEvents.InvoicePaid)
    schedule_cleanup()
    {:ok, %{table: table}}
  end

  @impl true
  def handle_call({:create_quote, amount, owner_session}, _from, state) do
    # Pin the active keyset to the quote at creation. All downstream
    # operations (pubkey push to client, signing) resolve the keyset by
    # this id, not by re-reading "whatever is active now". Eliminates
    # the DLEQ-mismatch race when the active keyset changes (rotation,
    # ETS scan order drift, restart) mid-deposit.
    case active_keyset_id() do
      nil ->
        {:reply, {:error, :no_active_keyset}, state}

      keyset_id ->
        case check_quote_capacity(owner_session) do
          :ok ->
            fee_schedule = Fees.from_config()

            {:ok, fee} = Fees.calculate(fee_schedule, amount, :deposit)
            quote = Quote.new(amount, fee, keyset_id, owner_session)
            persist_quote(quote.id, quote)

            :telemetry.execute([:minted, :mint, :quote, :created], %{amount: amount, fee: fee}, %{
              quote_id: quote.id
            })

            EventBus.publish(%MintEvents.QuoteCreated{
              quote_id: quote.id,
              timestamp: DateTime.utc_now()
            })

            {:reply, {:ok, quote}, state}

          {:error, _} = err ->
            {:reply, err, state}
        end
    end
  end

  def handle_call({:create_melt_quote, amount, bolt11, owner_session}, _from, state) do
    max_melt = Application.get_env(:minted, :max_melt_sats, @default_max_melt_sats)

    cond do
      amount > max_melt ->
        {:reply, {:error, :amount_too_large}, state}

      duplicate_active_melt_quote?(bolt11) ->
        # Refuse to open a second melt quote against a bolt11 that
        # already has an in-flight quote. Without this, two concurrent
        # melts collide into a single FireBird payment record (both
        # derive the same tracking hash from the invoice) — one melt's
        # settlement event never routes back and the other is silently
        # released while the invoice actually paid.
        {:reply, {:error, :duplicate_bolt11}, state}

      true ->
        # Melt fee reserve = routing-fee estimate the mint will forward
        # to phoenixd as `maxFeeFlatSat`. Using `Fees.calculate/3` with
        # `:withdrawal` returned 0 sats — that's an operator-margin
        # config (`withdrawal_fee_ppm`), not a routing reserve. A quote
        # with fee=0 meant every routed melt drained the mint's channel
        # balance for any route above the cheapest.
        fee = LightningFacade.routing_fee_estimate(amount)
        quote = Quote.new_melt(amount, fee, bolt11, owner_session)
        persist_quote(quote.id, quote)

        :telemetry.execute([:minted, :mint, :quote, :created], %{amount: amount, fee: fee}, %{
          quote_id: quote.id,
          type: :melt
        })

        EventBus.publish(%MintEvents.QuoteCreated{
          quote_id: quote.id,
          timestamp: DateTime.utc_now()
        })

        {:reply, {:ok, quote}, state}
    end
  end

  def handle_call(:clear, _from, state) do
    :ets.delete_all_objects(@table)
    :dets.delete_all_objects(@durable)
    {:reply, :ok, state}
  end

  def handle_call({:store_quote, %Quote{id: id} = quote}, _from, state) do
    :ets.insert(@table, {id, quote})
    {:reply, :ok, state}
  end

  def handle_call({:update_quote, id, transition_fn}, _from, state) do
    case :ets.lookup(@table, id) do
      [{^id, quote}] ->
        case transition_fn.(quote) do
          {:ok, updated} ->
            persist_quote(id, updated)

            EventBus.publish(
              %MintEvents.QuoteUpdated{
                quote_id: id,
                status: updated.status,
                timestamp: DateTime.utc_now()
              },
              id
            )

            {:reply, {:ok, updated}, state}

          {:error, _} = error ->
            {:reply, error, state}
        end

      [] ->
        {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  def terminate(_reason, _state) do
    :dets.close(@durable)
    :ok
  end

  @default_stale_paying_timeout_ms 600_000
  @default_stale_invoiced_timeout_ms 1_800_000

  @impl true
  def handle_info(:cleanup, state) do
    now = DateTime.utc_now()
    expire_old_quotes(now)
    recover_stale_claims(now)
    alert_stale_paying_quotes(now)
    alert_stale_invoiced_quotes(now)
    prune_terminal_quotes(now)
    schedule_cleanup()
    {:noreply, state}
  end

  def handle_info(%LightningEvents.InvoicePaid{quote_id: quote_id} = event, state)
      when is_binary(quote_id) do
    case try_mark_quote_paid(quote_id, event) do
      :pending ->
        # Race: invoice paid before attach_invoice completed. Retry with backoff.
        Process.send_after(self(), {:retry_mark_paid, event, 1}, @retry_mark_paid_delay_ms)

      _ ->
        :ok
    end

    {:noreply, state}
  end

  def handle_info(%LightningEvents.InvoicePaid{}, state) do
    # InvoicePaid without a quote_id — not linked to a mint quote.
    {:noreply, state}
  end

  def handle_info(
        {:retry_mark_paid, %LightningEvents.InvoicePaid{quote_id: quote_id} = event, attempt},
        state
      ) do
    case try_mark_quote_paid(quote_id, event) do
      :pending when attempt < @max_mark_paid_retries ->
        delay = @retry_mark_paid_delay_ms * attempt
        Logger.warning("Quotes: quote still pending, quote_id=#{quote_id}, attempt=#{attempt}, retry_ms=#{delay}")
        Process.send_after(self(), {:retry_mark_paid, event, attempt + 1}, delay)

      :pending ->
        Logger.error("Quotes: quote still pending after retries, quote_id=#{quote_id}, attempts=#{attempt}")

      _ ->
        :ok
    end

    {:noreply, state}
  end

  # Handle legacy 2-arity retry messages (in case any are in flight during deploy)
  def handle_info({:retry_mark_paid, event}, state) do
    handle_info({:retry_mark_paid, event, 1}, state)
  end

  defp try_mark_quote_paid(quote_id, event) do
    case :ets.lookup(@table, quote_id) do
      [{^quote_id, %Quote{status: :invoiced} = quote}] ->
        do_mark_quote_paid(quote_id, quote, event)

      [{^quote_id, %Quote{status: :pending}}] ->
        :pending

      _ ->
        :ok
    end
  end

  defp do_mark_quote_paid(quote_id, quote, event) do
    if Quote.expired?(quote) do
      Logger.warning("Quotes: rejecting payment for expired quote, quote_id=#{quote_id}")
      {:error, :quote_expired}
    else
      case Quote.mark_paid(quote, event.payment_hash) do
        {:ok, updated} ->
          persist_quote(quote_id, updated)

          EventBus.publish(%MintEvents.QuoteUpdated{
            quote_id: quote_id,
            status: :paid,
            timestamp: DateTime.utc_now()
          })

          :ok

        {:error, reason} ->
          Logger.warning("Quotes: could not mark quote #{quote_id} as paid: #{inspect(reason)}")

          {:error, reason}
      end
    end
  end

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup, @cleanup_interval_ms)
  end

  defp expire_old_quotes(now) do
    :ets.foldl(
      fn {id, quote}, acc ->
        if DateTime.compare(now, quote.expires_at) == :gt and
             quote.status in [:pending, :invoiced] do
          {:ok, expired} = Quote.expire(quote)
          persist_quote(id, expired)

          :telemetry.execute([:minted, :mint, :quote, :expired], %{}, %{quote_id: id})
        end

        acc
      end,
      :ok,
      @table
    )
  end

  # Issue #17: Lock quotes stuck in :claimed status for longer than the timeout.
  # This prevents the double-mint race (C2): if blind signing takes too long,
  # the quote is permanently locked rather than returned to :paid where it
  # could be claimed again, creating unbacked ecash liability.
  defp recover_stale_claims(now) do
    :ets.foldl(
      fn {id, quote}, acc ->
        maybe_recover_claim(id, quote, now)
        acc
      end,
      :ok,
      @table
    )
  end

  defp maybe_recover_claim(id, quote, now) do
    if quote.status == :claimed and stale_claim?(quote, now) do
      do_recover_claim(id, quote)
    end
  end

  defp do_recover_claim(id, quote) do
    case Quote.mark_stale_claimed(quote) do
      {:ok, locked} ->
        persist_quote(id, locked)

        Logger.warning("Quotes: locked stale claim, quote_id=#{id} — quote permanently failed to prevent double-mint")

        :telemetry.execute(
          [:minted, :mint, :quote, :stale_claim_locked],
          %{},
          %{quote_id: id}
        )

      {:error, _} ->
        :ok
    end
  end

  defp stale_claim?(quote, now) do
    case quote.claimed_at do
      nil -> false
      claimed_at -> DateTime.diff(now, claimed_at, :millisecond) > stale_claim_timeout_ms()
    end
  end

  @max_stale_claim_timeout_ms 600_000

  defp stale_claim_timeout_ms do
    configured = Application.get_env(:minted, :stale_claim_timeout_ms, @default_stale_claim_timeout_ms)
    min(configured, @max_stale_claim_timeout_ms)
  end

  defp alert_stale_paying_quotes(now) do
    timeout =
      Application.get_env(:minted, :stale_paying_timeout_ms, @default_stale_paying_timeout_ms)

    :ets.foldl(
      fn {id, quote}, acc ->
        if quote.status == :paying and stale_paying?(quote, now, timeout) do
          Logger.error(
            "Quotes: quote stuck in paying, quote_id=#{id}, stuck_minutes=#{div(timeout, 60_000)} — " <>
              "operator must verify Lightning payment status"
          )

          :telemetry.execute(
            [:minted, :mint, :quote, :stale_paying],
            %{},
            %{quote_id: id, paying_since: quote.paying_since}
          )
        end

        acc
      end,
      :ok,
      @table
    )
  end

  defp stale_paying?(quote, now, timeout) do
    case quote.paying_since do
      nil -> false
      paying_since -> DateTime.diff(now, paying_since, :millisecond) > timeout
    end
  end

  defp alert_stale_invoiced_quotes(now) do
    timeout =
      Application.get_env(:minted, :stale_invoiced_timeout_ms, @default_stale_invoiced_timeout_ms)

    :ets.foldl(
      fn {id, quote}, acc ->
        if quote.status == :invoiced and stale_invoiced?(quote, now, timeout) do
          Logger.warning(
            "Quotes: quote stuck in invoiced, quote_id=#{id}, stuck_minutes=#{div(timeout, 60_000)} — " <>
              "invoice may not have been presented to payer"
          )

          :telemetry.execute(
            [:minted, :mint, :quote, :stale_invoiced],
            %{},
            %{quote_id: id, created_at: quote.created_at}
          )
        end

        acc
      end,
      :ok,
      @table
    )
  end

  defp stale_invoiced?(quote, now, timeout) do
    DateTime.diff(now, quote.created_at, :millisecond) > timeout
  end

  # Remove quotes in terminal states older than 24 hours to prevent unbounded growth.
  @prune_age_seconds 86_400

  defp prune_terminal_quotes(now) do
    cutoff = DateTime.add(now, -@prune_age_seconds, :second)
    terminal_states = [:expired, :stale_claimed, :claimed]

    pruned =
      :ets.foldl(
        fn {id, quote}, acc ->
          if quote.status in terminal_states and DateTime.compare(quote.expires_at, cutoff) == :lt do
            :ets.delete(@table, id)
            :dets.delete(@durable, id)
            acc + 1
          else
            acc
          end
        end,
        0,
        @table
      )

    if pruned > 0 do
      :dets.sync(@durable)
      Logger.debug("Quotes: pruned terminal quotes, count=#{pruned}")
    end
  end

  defp active_keyset_id do
    case StorageFacade.get_active_keyset() do
      [%{id: id} | _] -> id
      _ -> nil
    end
  end

  # Bounds phoenixd invoice rows and quote-table growth from browser
  # wallet quote spam: the LiveView path has no PoW gate, so cap active
  # mint quotes globally and per owner session.
  defp check_quote_capacity(owner_session) do
    with :ok <- check_global_capacity() do
      check_owner_capacity(owner_session)
    end
  end

  defp check_global_capacity do
    max = Application.get_env(:minted, :max_active_mint_quotes, 1_000)

    if count_active_mint_quotes(nil) >= max do
      {:error, :too_many_active_quotes}
    else
      :ok
    end
  end

  defp check_owner_capacity(owner_session) when is_binary(owner_session) do
    max = Application.get_env(:minted, :max_active_mint_quotes_per_session, 5)

    if count_active_mint_quotes(owner_session) >= max do
      {:error, :too_many_active_quotes}
    else
      :ok
    end
  end

  # API-created quotes (nil owner) are PoW-gated upstream — no per-owner cap.
  defp check_owner_capacity(_owner_session), do: :ok

  defp count_active_mint_quotes(owner_session) do
    now = DateTime.utc_now()

    :ets.foldl(
      fn {_id, quote}, acc ->
        if capacity_relevant?(quote, now) and
             (owner_session == nil or quote.owner_session == owner_session) do
          acc + 1
        else
          acc
        end
      end,
      0,
      @table
    )
  end

  # A mint quote occupies capacity until it resolves: :pending
  # (invoice creation in flight), :invoiced (awaiting payment), or
  # :paid (awaiting claim) — and not past its TTL.
  defp capacity_relevant?(%Quote{type: :mint} = quote, now) do
    quote.status in [:pending, :invoiced, :paid] and
      DateTime.compare(now, quote.expires_at) != :gt
  end

  defp capacity_relevant?(_quote, _now), do: false

  defp persist_quote(id, quote) do
    :dets.insert(@durable, {id, quote})
    :dets.sync(@durable)
    :ets.insert(@table, {id, quote})
  end

  # Non-terminal melt statuses — a second quote on the same bolt11
  # while one is in these states risks a double-pay.
  @active_melt_statuses [:invoiced, :paying, :settlement_unknown]

  defp duplicate_active_melt_quote?(bolt11) when is_binary(bolt11) do
    :ets.foldl(
      fn
        {_id, %Quote{type: :melt, bolt11: ^bolt11, status: status}}, _acc
        when status in @active_melt_statuses ->
          true

        _entry, acc ->
          acc
      end,
      false,
      @table
    )
  rescue
    _ -> false
  end
end
