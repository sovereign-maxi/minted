defmodule Minted.Lightning.Manager do
  @moduledoc """
  Adapter GenServer bridging invoice operations to FireBird.

  Creates invoices via the configured client, tracks them via
  `FireBird.Manager`, and maintains a `quote_map` mapping
  `payment_hash_hex -> quote_id` for event bridge lookups.

  Polling is delegated entirely to FireBird.Manager.
  """

  use GenServer

  require Logger

  alias Minted.Events.EventBus
  alias Minted.Events.Lightning, as: LightningEvents
  alias Minted.Lightning.Adapters.Client
  alias Minted.Lightning.Breaker
  alias Minted.Lightning.Invoice
  alias Minted.Storage.Facade, as: StorageFacade

  @invoice_table Minted.Lightning.Manager
  @invoice_dets Minted.Lightning.Manager.Durable
  @quote_map_dets Minted.Lightning.Manager.QuoteMap
  @max_invoice_retries 3
  @initial_retry_delay_ms 100

  # --- Client API ---

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Creates a Lightning invoice via the configured client and stores it.

  Returns `{:ok, invoice}` or `{:error, reason}`.
  """
  @spec create_invoice(pos_integer(), String.t(), keyword()) ::
          {:ok, Invoice.t()} | {:error, term()}
  def create_invoice(amount_sats, description, opts \\ []) do
    server = Keyword.get(opts, :server, __MODULE__)
    # The retry ladder runs in a spawned task with up to 3 attempts at
    # a 30s HTTP receive timeout — the default 5s call timeout would
    # crash the caller while the invoice completes in the background.
    GenServer.call(server, {:create_invoice, amount_sats, description, opts}, 120_000)
  end

  @doc """
  Retrieves an invoice by payment_hash (hex string).
  """
  @spec get_invoice(String.t()) :: {:ok, Invoice.t()} | {:error, :not_found}
  def get_invoice(payment_hash_hex) do
    case decode_hex(payment_hash_hex) do
      {:ok, hash_bin} ->
        case FireBird.Manager.lookup(@invoice_table, hash_bin) do
          {:ok, fb_invoice} ->
            # external_id is set to quote_id by Invoice.to_firebird/1; no
            # separate DETS lookup needed.
            {:ok, Invoice.from_firebird(fb_invoice)}

          {:error, :not_found} ->
            {:error, :not_found}
        end

      :error ->
        {:error, :not_found}
    end
  end

  @doc """
  Returns all invoices with `:pending` status.
  """
  @spec list_pending() :: [Invoice.t()]
  def list_pending do
    case :ets.whereis(@invoice_table) do
      :undefined ->
        []

      _ref ->
        @invoice_table
        |> FireBird.Manager.list()
        |> Enum.filter(fn inv -> inv.status == :pending end)
        |> Enum.map(&Invoice.from_firebird/1)
    end
  end

  @doc """
  Clears all invoices. Intended for use in tests.
  """
  @spec clear() :: :ok
  def clear do
    case :ets.whereis(@invoice_table) do
      :undefined -> :ok
      _ref -> :ets.delete_all_objects(@invoice_table)
    end

    # Clear invoice DETS if open.
    case :dets.info(@invoice_dets) do
      :undefined -> :ok
      _ -> :dets.delete_all_objects(@invoice_dets)
    end

    case Process.whereis(__MODULE__) do
      nil -> :ok
      _pid -> GenServer.call(__MODULE__, :clear_quote_map)
    end

    :ok
  end

  @doc """
  Marks an invoice as paid (async). Called by the Webhook or polling loop.
  """
  @spec mark_paid(String.t(), String.t(), keyword()) :: :ok
  def mark_paid(payment_hash, preimage, opts \\ []) do
    server = Keyword.get(opts, :server, __MODULE__)
    GenServer.cast(server, {:mark_paid, payment_hash, preimage})
  end

  @doc """
  Marks an invoice as paid (sync). Returns :ok or {:error, reason}.
  """
  @spec mark_paid_sync(String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def mark_paid_sync(payment_hash, preimage, opts \\ []) do
    server = Keyword.get(opts, :server, __MODULE__)
    GenServer.call(server, {:mark_paid, payment_hash, preimage})
  end

  @doc """
  Verifies payment amount with the client before marking paid.
  """
  @spec verify_and_mark_paid(String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def verify_and_mark_paid(payment_hash, preimage, opts \\ []) do
    server = Keyword.get(opts, :server, __MODULE__)
    GenServer.call(server, {:verify_and_mark_paid, payment_hash, preimage}, 10_000)
  end

  # --- GenServer callbacks ---

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    _pubsub = Keyword.get(opts, :pubsub)

    # Open quote_map DETS.
    qm_path = StorageFacade.lightning_invoice_quote_map_path() |> String.to_charlist()
    {:ok, _} = :dets.open_file(@quote_map_dets, file: qm_path, type: :set)

    quote_map =
      :dets.foldl(fn {k, v}, acc -> Map.put(acc, k, v) end, %{}, @quote_map_dets)

    # Open invoice DETS and restore into ETS.
    inv_path = StorageFacade.lightning_invoices_path() |> String.to_charlist()
    {:ok, _} = :dets.open_file(@invoice_dets, file: inv_path, type: :set)

    if :ets.whereis(@invoice_table) == :undefined do
      :ets.new(@invoice_table, [:named_table, :set, :public, read_concurrency: true])
    end

    :dets.foldl(
      fn {hash_bin, fb_invoice}, _acc ->
        :ets.insert(@invoice_table, {hash_bin, fb_invoice})
      end,
      :ok,
      @invoice_dets
    )

    # Re-register any invoices still `:pending` with FireBird.Manager
    # so its polling loop resumes settlement detection after a crash.
    # Without this, an invoice that was paid while the mint was down
    # would never surface an `InvoicePaid` event — the mint's poll
    # loop wouldn't know it existed. The Lightning supervisor starts
    # FireBird.Supervisor before this GenServer, so FireBird.Manager
    # is already alive.
    retrack_pending_with_firebird()

    {:ok, %{quote_map: quote_map}}
  end

  defp retrack_pending_with_firebird do
    case Process.whereis(FireBird.Manager) do
      nil ->
        :ok

      _pid ->
        :ets.foldl(
          fn
            {_hash, %FireBird.Invoice{status: :pending} = fb_invoice}, _acc ->
              FireBird.Manager.track(FireBird.Manager, fb_invoice)

            {_hash, _terminal}, _acc ->
              :ok
          end,
          :ok,
          @invoice_table
        )
    end
  end

  @impl true
  def handle_call(:clear_quote_map, _from, state) do
    :dets.delete_all_objects(@quote_map_dets)
    :dets.delete_all_objects(@invoice_dets)
    {:reply, :ok, %{state | quote_map: %{}}}
  end

  def handle_call({:create_invoice, amount_sats, description, opts}, from, state) do
    handle_create_invoice(amount_sats, description, opts, from, state)
  end

  def handle_call({:mark_paid, payment_hash, preimage}, _from, state) do
    result = do_mark_paid(payment_hash, preimage, state)
    {:reply, result, state}
  end

  def handle_call({:verify_and_mark_paid, payment_hash, preimage}, _from, state) do
    result = do_verify_and_mark_paid(payment_hash, preimage, state)
    {:reply, result, state}
  end

  def handle_call({:get_quote_id, payment_hash_hex}, _from, state) do
    {:reply, Map.get(state.quote_map, payment_hash_hex), state}
  end

  @impl true
  def handle_cast({:mark_paid, payment_hash, preimage}, state) do
    case do_mark_paid(payment_hash, preimage, state) do
      :ok ->
        :ok

      {:error, :invoice_not_found} ->
        Logger.warning("Manager: async mark_paid — invoice not found for #{redact_hash(payment_hash)}")

      {:error, reason} ->
        Logger.warning("Manager: async mark_paid failed for #{redact_hash(payment_hash)}: #{inspect(reason)}")
    end

    {:noreply, state}
  end

  def handle_info(
        {:invoice_task_result, from, amount_sats, opts, {:ok, %{"paymentHash" => hash_hex, "serialized" => bolt11}}},
        state
      ) do
    quote_id = Keyword.get(opts, :quote_id)

    invoice =
      Invoice.new(
        payment_hash: hash_hex,
        bolt11: bolt11,
        amount_sats: amount_sats,
        quote_id: quote_id
      )

    fb_invoice = Invoice.to_firebird(invoice)

    case Process.whereis(FireBird.Manager) do
      nil -> :ok
      _pid -> FireBird.Manager.track(FireBird.Manager, fb_invoice)
    end

    persist_invoice(fb_invoice.payment_hash, fb_invoice)

    {state, reply} =
      if quote_id do
        case Map.get(state.quote_map, hash_hex) do
          nil ->
            persist_quote_map_entry(hash_hex, quote_id)
            {%{state | quote_map: Map.put(state.quote_map, hash_hex, quote_id)}, {:ok, invoice}}

          existing_quote_id ->
            Logger.warning(
              "Manager: duplicate payment_hash #{redact_hash(hash_hex)} — " <>
                "already mapped to quote=#{existing_quote_id}, rejecting new quote=#{quote_id}"
            )

            {state, {:error, :duplicate_payment_hash}}
        end
      else
        {state, {:ok, invoice}}
      end

    GenServer.reply(from, reply)
    {:noreply, state}
  end

  def handle_info({:invoice_task_result, from, _amount_sats, _opts, {:error, reason}}, state) do
    GenServer.reply(from, {:error, reason})
    {:noreply, state}
  end

  def handle_info({:EXIT, pid, :normal}, state) do
    Logger.debug("Manager: Linked process #{inspect(pid)} exited normally")
    {:noreply, state}
  end

  def handle_info({:EXIT, pid, reason}, state) do
    Logger.warning("Manager: Linked process #{inspect(pid)} exited: #{inspect(reason)}")

    :telemetry.execute(
      [:minted, :lightning, :invoice_manager, :linked_exit],
      %{count: 1},
      %{pid: inspect(pid), reason: inspect(reason)}
    )

    {:noreply, state}
  end

  @impl true
  def handle_info(msg, state) do
    Logger.debug("Manager: Unhandled message: #{inspect(msg)}")
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, _state) do
    :dets.close(@quote_map_dets)
    :dets.close(@invoice_dets)
    :ok
  end

  # --- Private ---

  defp handle_create_invoice(amount_sats, description, opts, from, state) do
    parent = self()

    # Callers with an application-layer TTL (mint quote, checkout
    # window) pass `:expiry_seconds` so the phoenixd invoice can't
    # outlive the quote.
    expiry = Keyword.get(opts, :expiry_seconds)

    # Spawn an unlinked task so exponential backoff sleeps do not block the
    # GenServer.  The task sends its result back via handle_info, which then
    # updates state and calls GenServer.reply/2.
    Task.start(fn ->
      {client_mod, client_config} = Client.client_tuple()
      result = create_invoice_with_retry(client_mod, client_config, amount_sats, description, expiry)
      send(parent, {:invoice_task_result, from, amount_sats, opts, result})
    end)

    {:noreply, state}
  end

  defp do_mark_paid(payment_hash_hex, preimage_hex, state) do
    case decode_hex(payment_hash_hex) do
      {:ok, hash_bin} ->
        case :ets.lookup(@invoice_table, hash_bin) do
          [{^hash_bin, fb_invoice}] ->
            mark_fb_invoice_paid(fb_invoice, hash_bin, payment_hash_hex, preimage_hex, state)

          [] ->
            Logger.debug("Manager: received payment for unknown invoice: #{redact_hash(payment_hash_hex)}")
            {:error, :invoice_not_found}
        end

      :error ->
        {:error, :invalid_payment_hash}
    end
  end

  defp mark_fb_invoice_paid(fb_invoice, hash_bin, payment_hash_hex, preimage_hex, state) do
    case decode_hex(preimage_hex) do
      {:ok, preimage_bin} ->
        case FireBird.Invoice.mark_paid(fb_invoice, preimage_bin) do
          {:ok, updated} ->
            persist_invoice(hash_bin, updated)
            quote_id = Map.get(state.quote_map, payment_hash_hex, fb_invoice.external_id)

            EventBus.publish(%LightningEvents.InvoicePaid{
              payment_hash: payment_hash_hex,
              amount_sats: updated.amount_sats,
              preimage: preimage_hex,
              quote_id: quote_id,
              timestamp: DateTime.utc_now()
            })

            :ok

          {:error, :not_pending} ->
            # Idempotent re-mark
            :ok

          {:error, _reason} = err ->
            err
        end

      :error ->
        {:error, :preimage_mismatch}
    end
  end

  defp do_verify_and_mark_paid(payment_hash_hex, preimage_hex, state) do
    case decode_hex(payment_hash_hex) do
      {:ok, hash_bin} ->
        case :ets.lookup(@invoice_table, hash_bin) do
          [{^hash_bin, fb_invoice}] ->
            verify_with_client(fb_invoice, hash_bin, payment_hash_hex, preimage_hex, state)

          [] ->
            {:error, :invoice_not_found}
        end

      :error ->
        {:error, :invalid_payment_hash}
    end
  end

  defp verify_with_client(fb_invoice, hash_bin, payment_hash_hex, preimage_hex, state) do
    {client_mod, client_config} = Client.client_tuple()

    case Breaker.call(:phoenixd, fn -> client_mod.get_incoming_payment(client_config, hash_bin) end) do
      {:error, :circuit_open} ->
        Logger.warning("Manager: Phoenixd circuit open, skipping verification for #{redact_hash(payment_hash_hex)}")

        {:error, :verification_failed}

      {:ok, %{"isPaid" => true, "receivedSat" => received_sat}}
      when is_integer(received_sat) ->
        if received_sat >= fb_invoice.amount_sats do
          do_mark_paid(payment_hash_hex, preimage_hex, state)
        else
          :telemetry.execute(
            [:minted, :lightning, :invoice, :underpaid],
            %{expected: fb_invoice.amount_sats, received: received_sat},
            %{payment_hash: payment_hash_hex}
          )

          Logger.error(
            "Manager: underpaid invoice #{redact_hash(payment_hash_hex)} (webhook): " <>
              "expected=#{fb_invoice.amount_sats} received=#{received_sat}"
          )

          {:error, :underpaid}
        end

      {:ok, _} ->
        {:error, :not_paid}

      {:error, reason} ->
        Logger.warning("Manager: could not verify payment #{redact_hash(payment_hash_hex)}: #{inspect(reason)}")

        {:error, :verification_failed}
    end
  end

  defp create_invoice_with_retry(client_mod, client_config, amount, description, expiry, retries \\ 0) do
    case Breaker.call(:phoenixd, fn ->
           client_mod.create_invoice(client_config, amount, description, expiry)
         end) do
      {:error, :circuit_open} ->
        Logger.error("Manager: Phoenixd circuit open, invoice creation blocked")
        {:error, :circuit_open}

      {:ok, _} = success ->
        success

      {:error, reason} when retries < @max_invoice_retries ->
        delay = trunc(@initial_retry_delay_ms * :math.pow(2, retries))

        Logger.warning(
          "Manager: invoice creation failed (attempt #{retries + 1}): #{inspect(reason)}, retrying in #{delay}ms"
        )

        Process.sleep(delay)
        create_invoice_with_retry(client_mod, client_config, amount, description, expiry, retries + 1)

      {:error, _} = error ->
        error
    end
  end

  defp persist_invoice(hash_bin, fb_invoice) do
    case :dets.insert(@invoice_dets, {hash_bin, fb_invoice}) do
      :ok ->
        case :dets.sync(@invoice_dets) do
          :ok ->
            :ok

          {:error, reason} ->
            Logger.error("Manager: DETS sync failed: #{inspect(reason)}")
        end

      {:error, reason} ->
        Logger.error("Manager: DETS insert failed: #{inspect(reason)}")
    end

    :ets.insert(@invoice_table, {hash_bin, fb_invoice})
  end

  defp persist_quote_map_entry(hash_hex, quote_id) do
    case :dets.insert(@quote_map_dets, {hash_hex, quote_id}) do
      :ok ->
        case :dets.sync(@quote_map_dets) do
          :ok ->
            :ok

          {:error, reason} ->
            Logger.error("Manager: quote_map DETS sync failed: #{inspect(reason)}")
        end

      {:error, reason} ->
        Logger.error("Manager: quote_map DETS insert failed: #{inspect(reason)}")
    end
  end

  defp redact_hash(hash) when is_binary(hash) and byte_size(hash) > 8 do
    String.slice(hash, 0, 8) <> "..."
  end

  defp redact_hash(hash), do: hash

  defp decode_hex(hex) when is_binary(hex), do: Base.decode16(hex, case: :mixed)
  defp decode_hex(_), do: :error
end
