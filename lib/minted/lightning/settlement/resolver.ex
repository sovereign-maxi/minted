defmodule Minted.Lightning.Settlement.Resolver do
  @moduledoc """
  Periodically resolves melt quotes stuck in `:settlement_unknown` status.

  When a melt payment times out, the outcome is ambiguous — the payment
  may have settled on Lightning or not. Tokens are held reserved (fail-closed)
  and the quote enters `:settlement_unknown`.

  This GenServer polls Phoenixd to determine the actual outcome and
  either commits the reservation (payment settled) or releases it
  (payment failed), unblocking the user's tokens.
  """

  use GenServer

  require Logger

  alias Minted.Lightning.Adapters.Client
  alias Minted.Lightning.Breaker
  alias Minted.Mint.Facade
  alias Minted.Mint.Quote
  alias Minted.Mint.Spent

  @default_poll_interval_ms 60_000
  @default_min_age_ms 600_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl GenServer
  def init(opts) do
    poll_interval = Keyword.get(opts, :poll_interval_ms, @default_poll_interval_ms)
    min_age_ms = Keyword.get(opts, :min_age_ms, @default_min_age_ms)

    timer = Process.send_after(self(), :resolve, poll_interval)

    {:ok,
     %{
       timer: timer,
       poll_interval_ms: poll_interval,
       min_age_ms: min_age_ms
     }}
  end

  @doc "Triggers an immediate resolution cycle. Blocks until complete."
  @spec resolve_now(GenServer.server()) :: :ok
  def resolve_now(server \\ __MODULE__) do
    GenServer.call(server, :resolve_now)
  end

  @impl GenServer
  def handle_call(:resolve_now, _from, state) do
    resolve_unknown_settlements(state)
    {:reply, :ok, state}
  end

  @impl GenServer
  def handle_info(:resolve, state) do
    resolve_unknown_settlements(state)
    timer = Process.send_after(self(), :resolve, state.poll_interval_ms)
    {:noreply, %{state | timer: timer}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp resolve_unknown_settlements(state) do
    quotes = Facade.list_quotes_by_status(:settlement_unknown)

    if quotes != [] do
      Logger.info("Resolver: checking #{length(quotes)} settlement_unknown quote(s)")
    end

    Enum.each(quotes, fn quote -> try_resolve(quote, state) end)
  end

  defp try_resolve(quote, state) do
    if old_enough?(quote, state.min_age_ms) do
      case quote.melt_context do
        %{ln_payment_hash: <<_::binary>> = hash} ->
          do_resolve(quote, hash)

        _ ->
          Logger.warning(
            "Resolver: quote missing ln_payment_hash, manual operator resolution required, " <>
              "quote_id=#{truncate(quote.id)}"
          )
      end
    end
  end

  defp do_resolve(quote, ln_payment_hash) do
    case check_payment_status(ln_payment_hash) do
      {:settled, preimage, routing_fee} ->
        handle_settled(quote, preimage, routing_fee)

      :failed ->
        handle_failed(quote)

      :pending ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "Resolver: payment status check failed, reservation held, operator resolution required, " <>
            "quote_id=#{truncate(quote.id)}, reason=#{inspect(reason)}"
        )
    end
  end

  # Clause order matters. Phoenixd's failed-payment response carries
  # BOTH `"isPaid" => false` AND a non-nil `"completedAt"`; matching
  # `isPaid=false` first would classify a definitively-failed payment
  # as `:pending` forever. Check `completedAt` first, then fall back
  # to still-pending.
  #
  # We NEVER release on a 4xx/5xx from the node — outcome is
  # undetermined, not definitively failed. Releasing on 404 would
  # double-spend if the payment settled and the record was later purged.
  defp check_payment_status(ln_payment_hash) do
    {client_mod, config} = Client.client_tuple()

    case Breaker.call(:phoenixd, fn ->
           client_mod.get_outgoing_payment_by_hash(config, ln_payment_hash)
         end) do
      {:ok, %{"isPaid" => true, "preimage" => preimage} = result} ->
        routing_fee = Map.get(result, "routingFeeSat", 0)
        {:settled, preimage, routing_fee}

      {:ok, %{"completedAt" => completed}} when not is_nil(completed) ->
        :failed

      {:ok, _still_pending} ->
        :pending

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp handle_settled(quote, _preimage, _routing_fee) do
    entries = reservation_entries(quote.melt_context)

    case Spent.commit_reserved(entries) do
      :ok ->
        Facade.update_quote(quote.id, &Quote.mark_paid/1)
        Facade.update_quote(quote.id, &Quote.claim/1)

        :telemetry.execute(
          [:minted, :settlement_resolver, :resolved],
          %{count: 1},
          %{outcome: :settled, quote_id: truncate(quote.id), amount: quote.amount}
        )

        Logger.info(
          "Resolver: quote #{truncate(quote.id)} resolved as SETTLED — " <>
            "tokens committed, #{quote.amount} sats"
        )

      {:error, reason} ->
        Logger.error("Resolver: commit failed for quote #{truncate(quote.id)}: #{inspect(reason)}")
    end
  end

  defp handle_failed(quote) do
    entries = reservation_entries(quote.melt_context)

    Spent.release_reserved(entries)
    Facade.update_quote(quote.id, &Quote.abort_payment/1)

    :telemetry.execute(
      [:minted, :settlement_resolver, :resolved],
      %{count: 1},
      %{outcome: :failed, quote_id: truncate(quote.id), amount: quote.amount}
    )

    Logger.info(
      "Resolver: quote #{truncate(quote.id)} resolved as FAILED — " <>
        "tokens released, #{quote.amount} sats returned"
    )
  end

  # API-path melts carry a single keyset's tokens.
  defp reservation_entries(%{tokens: tokens, keyset_id: keyset_id}) do
    Enum.map(tokens, fn t -> {t.secret, keyset_id} end)
  end

  # Wallet-path melts can span multiple keysets — one token group each.
  defp reservation_entries(%{groups: groups}) when is_list(groups) do
    Enum.flat_map(groups, fn {keyset_id, tokens} ->
      Enum.map(tokens, fn t -> {t.secret, keyset_id} end)
    end)
  end

  defp old_enough?(quote, min_age_ms) do
    case quote.paying_since do
      %DateTime{} = since ->
        age_ms = DateTime.diff(DateTime.utc_now(), since, :millisecond)
        age_ms >= min_age_ms

      nil ->
        true
    end
  end

  defp truncate(id) when is_binary(id) and byte_size(id) > 8 do
    binary_part(id, 0, 8) <> "..."
  end

  defp truncate(id), do: id
end
