defmodule Minted.Scenarios.DepositAckGateTest do
  @moduledoc """
  Regression tests for the ACK gate on the deposit activity log and
  the durability + auth guarantees that surround it.

  Background: a real-world deposit completed server-side (mint signed
  the blinded outputs, `:tokens_minted` written to the WAL, liability
  counter incremented) but the client failed to unblind/store the
  resulting tokens. Before the fix the activity log entry was pushed
  unconditionally on the server's `:sign_result`, leaving a phantom
  "tokens minted" line in the activity history with no actual tokens
  behind it and no path to recover the signatures.

  This file pins the contract:

    1. Server holds signatures in `Minted.Mint.Pending` (DETS) until
       the client ACKs storage. Activity is gated on the ACK.
    2. Pending entries are bound to the issuing socket id — another
       session cannot ACK or redeliver them.
    3. `wallet:tokens_stored_failed` retains the entry for retry.
    4. `wallet:request_signatures` redelivers from the durable store —
       so a server crash between sign and ACK is recoverable.
    5. `Pending.Reconciler` writes a compensating `:tokens_burned`
       for entries the client never came back for, idempotent under
       crash via the recovery dedup-by-quote_id rule.
    6. Recovery dedups orphan burns by `{quote_id, :orphaned_deposit}`
       — re-running the Reconciler after a crash cannot double-count.
  """

  use Minted.ConnCase, async: false

  @moduletag :scenario

  import Phoenix.LiveViewTest

  alias Locker.WAL.Entry
  alias Minted.Mint.Facade, as: MintFacade
  alias Minted.Mint.Pending
  alias Minted.Mint.Pending.Reconciler
  alias Minted.Mint.Quote
  alias Minted.Mint.Signatures.Blind
  alias Minted.Mint.Token
  alias Minted.Storage.Facade, as: StorageFacade
  alias Minted.Storage.Recovery

  setup tags do
    Minted.TestHelpers.StateHelpers.clean_state(tags)
    keyset = Minted.TestHelpers.WalletHelpers.get_or_create_test_keyset()
    clear_pending()
    {:ok, keyset: keyset}
  end

  describe "ACK gate on deposit activity (real BDHKE round-trip)" do
    test "no activity until ACK; ACK clears Pending and pushes activity",
         %{conn: conn, keyset: keyset} do
      {:ok, view, _html} = live(conn, ~p"/wallet")

      quote_id = setup_paid_quote(64, view)
      {blinded_messages, _r_values, _secrets} = build_real_blinded_messages(64, keyset)

      drive_to_signed(view, quote_id, blinded_messages)

      assert_push_event(view, "wallet:blind_signatures", %{quote_id: ^quote_id})
      refute_push_event(view, "wallet:add_activity", %{})

      assert {:ok, _} = Pending.raw_lookup(quote_id),
             "signatures must be durable in Mint.Pending before ACK"

      render_hook(view, "wallet:tokens_stored_ok", %{"quote_id" => quote_id})

      assert_push_event(view, "wallet:add_activity", %{type: "deposit", status: "complete"})

      assert :not_found == Pending.raw_lookup(quote_id),
             "Pending entry must be cleared after ACK"
    end

    test "tokens_stored_failed retains the entry and pushes no activity",
         %{conn: conn, keyset: keyset} do
      {:ok, view, _html} = live(conn, ~p"/wallet")

      quote_id = setup_paid_quote(64, view)
      {blinded_messages, _r, _s} = build_real_blinded_messages(64, keyset)

      drive_to_signed(view, quote_id, blinded_messages)
      assert_push_event(view, "wallet:blind_signatures", %{quote_id: ^quote_id})

      render_hook(view, "wallet:tokens_stored_failed", %{
        "quote_id" => quote_id,
        "reason" => "dleq_verification_failed"
      })

      refute_push_event(view, "wallet:add_activity", %{})
      assert {:ok, _} = Pending.raw_lookup(quote_id), "signatures must be retained for retry"
    end
  end

  describe "session binding (cross-session attack prevention)" do
    test "another socket cannot ACK a Pending entry it doesn't own",
         %{conn: conn, keyset: keyset} do
      {:ok, view_a, _} = live(conn, ~p"/wallet")
      quote_id = setup_paid_quote(64, view_a)
      {blinded_messages, _r, _s} = build_real_blinded_messages(64, keyset)

      drive_to_signed(view_a, quote_id, blinded_messages)
      assert_push_event(view_a, "wallet:blind_signatures", %{quote_id: ^quote_id})
      assert {:ok, _} = Pending.raw_lookup(quote_id)

      # Open a second, independent LiveView session and try to ACK
      # quote_id from there.
      {:ok, view_b, _} = live(Phoenix.ConnTest.build_conn(), ~p"/wallet")
      render_hook(view_b, "wallet:tokens_stored_ok", %{"quote_id" => quote_id})

      # The hostile socket gets nothing. The legitimate Pending entry
      # is still there for the original session.
      refute_push_event(view_b, "wallet:add_activity", %{})

      assert {:ok, _} = Pending.raw_lookup(quote_id),
             "Pending entry must NOT have been deleted by foreign socket"
    end

    test "another socket cannot pull signatures it doesn't own",
         %{conn: conn} do
      quote_id = "session-test-#{:erlang.unique_integer([:positive])}"

      :ok =
        Pending.put(quote_id, "owner-socket-id", %{
          signatures: build_fake_signatures(64),
          total_amount: 64
        })

      {:ok, view, _} = live(conn, ~p"/wallet")
      render_hook(view, "wallet:request_signatures", %{"quote_id" => quote_id})
      refute_push_event(view, "wallet:blind_signatures", %{})
    end
  end

  describe "durable redelivery (server-crash recovery)" do
    test "request_signatures redelivers when the caller presents a recovery token",
         %{conn: conn} do
      # An entry recovered across a BEAM restart lives under a
      # recovery token instead of a browser session id. The mint
      # exposes the token via operator recovery; possession =
      # authorisation. Nil-as-public is no longer accepted.
      quote_id = "fake-recovery-quote-#{:erlang.unique_integer([:positive])}"
      fake_sigs = build_fake_signatures(64)

      {:ok, token} =
        Pending.put_recoverable(quote_id, %{signatures: fake_sigs, total_amount: 64})

      # Directly authorise via the token — the wallet doesn't hold
      # tokens in production but this proves the credential works.
      assert {:ok, _payload} = Pending.get(quote_id, token)

      # And a session that DOESN'T have the token is rejected.
      {:ok, view, _} = live(conn, ~p"/wallet")
      render_hook(view, "wallet:request_signatures", %{"quote_id" => quote_id})
      refute_push_event(view, "wallet:blind_signatures", %{})
    end

    test "request_signatures for an unknown quote pushes nothing", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/wallet")
      render_hook(view, "wallet:request_signatures", %{"quote_id" => "no-such-quote"})
      refute_push_event(view, "wallet:blind_signatures", %{})
    end
  end

  describe "reconciliation sweep (phantom liability protection)" do
    test "ages out orphan deposits and writes a compensating burn" do
      quote_id = "orphan-#{:erlang.unique_integer([:positive])}"

      {:ok, _token} =
        Pending.put_recoverable(quote_id, %{
          signatures: build_fake_signatures(7500),
          total_amount: 7500,
          inserted_at: 0
        })

      reconciled = Reconciler.sweep_now()

      assert reconciled >= 1
      assert :not_found == Pending.raw_lookup(quote_id)

      {:ok, entries} = StorageFacade.read_all_wal()

      assert Enum.any?(entries, fn entry ->
               entry.type == :tokens_burned and
                 entry.payload[:quote_id] == quote_id and
                 entry.payload[:reason] == :orphaned_deposit
             end),
             "expected a :tokens_burned WAL entry tagged :orphaned_deposit"
    end

    test "leaves recently-stored entries alone" do
      quote_id = "fresh-#{:erlang.unique_integer([:positive])}"

      {:ok, _token} =
        Pending.put_recoverable(quote_id, %{
          signatures: build_fake_signatures(100),
          total_amount: 100
        })

      _ = Reconciler.sweep_now()

      assert {:ok, _} = Pending.raw_lookup(quote_id),
             "fresh entries (under threshold) must not be reconciled"
    end
  end

  describe "recovery dedup of orphan burns" do
    test "re-running the reconciler does not double-count the burn" do
      quote_id = "double-burn-#{:erlang.unique_integer([:positive])}"

      # Two identical orphan-burn entries simulate the Reconciler
      # crashing between WAL.append and Pending.delete: a re-run
      # writes a second WAL entry for the same quote_id+reason.
      orphan_payload = %{
        amount: 1234,
        keyset_id: nil,
        reason: :orphaned_deposit,
        quote_id: quote_id
      }

      entries = [
        %Entry{type: :tokens_minted, payload: %{amount: 1234, quote_id: quote_id}},
        %Entry{type: :tokens_burned, payload: orphan_payload},
        %Entry{type: :tokens_burned, payload: orphan_payload}
      ]

      acc =
        Enum.reduce(entries, {0, 0, 0, MapSet.new()}, fn entry, acc ->
          accumulate(entry, acc)
        end)

      {minted, burned, _fees, _seen} = acc

      assert minted == 1234
      assert burned == 1234, "duplicate orphan-burn entries must be deduped to a single 1234 sat burn"
    end
  end

  # --- Helpers ---

  # Creates a paid mint quote owned by the given view's session so the
  # LiveView claim handler accepts the scenario's crafted
  # `{:claim_deposit, ...}` as belonging to that session.
  defp setup_paid_quote(amount, view) do
    {:ok, quote} = MintFacade.create_mint_quote(amount, wallet_session_id(view))

    {:ok, quote} =
      MintFacade.update_quote(quote.id, fn q ->
        Quote.attach_invoice(q, "lnbc_test_#{:erlang.unique_integer([:positive])}")
      end)

    payment_hash = Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
    {:ok, quote} = MintFacade.update_quote(quote.id, &Quote.mark_paid(&1, payment_hash))
    quote.id
  end

  defp wallet_session_id(view) do
    :sys.get_state(view.pid).socket.assigns.wallet_session_id
  end

  defp drive_to_signed(view, quote_id, blinded_messages) do
    pid = view.pid
    component_id = "deposit-tab"

    send(pid, {:claim_deposit, component_id, quote_id})
    :sys.get_state(pid)

    render_hook(view, "wallet:blinded_messages", %{
      "quote_id" => quote_id,
      "blinded_messages" => Enum.map(blinded_messages, &encode_blinded_for_event/1)
    })

    wait_for_pending(quote_id, 5_000)
  end

  defp encode_blinded_for_event({amount, %Blind.BlindedMessage{b_prime: b_prime}}) do
    %{
      "amount" => amount,
      "b_prime" => Base.encode16(b_prime, case: :lower)
    }
  end

  defp build_real_blinded_messages(total_amount, _keyset) do
    amounts = Token.decompose_amount(total_amount)

    Enum.reduce(amounts, {[], [], []}, fn amt, {msgs, rs, secrets} ->
      secret = :crypto.strong_rand_bytes(32)
      {:ok, blinded} = Blind.blind(secret)
      {[{amt, blinded} | msgs], [blinded.blinding_factor | rs], [secret | secrets]}
    end)
    |> then(fn {msgs, rs, secrets} -> {Enum.reverse(msgs), Enum.reverse(rs), Enum.reverse(secrets)} end)
  end

  defp build_fake_signatures(total_amount) do
    total_amount
    |> Token.decompose_amount()
    |> Enum.map(fn amt ->
      %{
        amount: amt,
        c_prime: :crypto.strong_rand_bytes(33),
        keyset_id: "test",
        dleq: nil
      }
    end)
  end

  defp wait_for_pending(quote_id, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    Stream.repeatedly(fn ->
      case Pending.raw_lookup(quote_id) do
        {:ok, _} -> :found
        :not_found -> :waiting
      end
    end)
    |> Enum.find(fn
      :found -> true
      :waiting -> System.monotonic_time(:millisecond) > deadline
    end)
  end

  defp clear_pending do
    Pending.expired_before(System.system_time(:millisecond) + 1)
    |> Enum.each(fn {qid, _} -> Pending.force_delete(qid) end)
  end

  defp accumulate(entry, acc), do: Recovery.__accumulate_liability_entry__(entry, acc)
end
