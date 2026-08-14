defmodule Minted.Telemetry.Publishers.Nostr do
  @moduledoc """
  Publishes operator alerts as NIP-17 gift-wrapped DMs over Nostr.

  Subscribes to `AlertFired` and `AlertResolved` events on the EventBus,
  filters by severity, formats the payload, and sends an encrypted
  gift-wrapped direct message to the operator's Nostr pubkey via configured
  relays.

  ## Configuration

      config :minted, :nostr,
        operator_pubkey: "<64-char-hex-xonly-pubkey>",
        relays: ["wss://relay.damus.io", ...],
        alert_severities: [:emergency, :critical, :warning]

  ## NIP-17 flow

  Each alert becomes three nested events:

    1. **Rumor** (kind 14, unsigned) — the actual message content with a
       p-tag to the recipient.
    2. **Seal** (kind 13) — the rumor serialised as JSON, encrypted with
       NIP-44 using the sender's signing key, signed by the sender. The
       seal's `created_at` is randomised within the last 2 days to hide
       timing correlation.
    3. **Gift wrap** (kind 1059) — the seal serialised as JSON, encrypted
       with NIP-44 using a fresh ephemeral keypair, signed by that ephemeral
       key. The gift wrap's pubkey is therefore unlinkable to the sender,
       providing metadata privacy at the relay layer.

  The sender's signing key is loaded from an encrypted key file with the label
  `"nostr_signing_key"` — the same key used by
  `Minted.Reserves.Publishers.Nostr` for reserve proofs. Only the ephemeral
  gift-wrap key is generated per message.
  """

  use GenServer

  require Logger

  alias Minted.Events.{Display, EventBus}
  alias Minted.Events.Telemetry, as: TelemetryEvents
  alias Minted.Telemetry.Publishers.Nostr.Nip44

  @kind_rumor 14
  @kind_seal 13
  @kind_gift_wrap 1059

  @key_label "nostr_signing_key"
  @default_severities [:emergency, :critical, :warning]

  # Randomise seal / gift wrap timestamps within the last 2 days (per NIP-59).
  @timestamp_jitter_seconds 2 * 24 * 60 * 60

  # Proof-of-life DM. Fires at `interval_ms` from process start.
  # Absence of the expected heartbeat is a signal something is
  # wrong with the publisher or the node, not absence of alerts.
  # Both interval + enabled are Ansible-configurable via env.
  @default_heartbeat_interval_ms 24 * 60 * 60 * 1000

  # --- Public API ---

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "Returns the hex pubkey used for the seal layer, if available."
  @spec pubkey() :: {:ok, String.t()} | {:error, :not_available}
  def pubkey, do: GenServer.call(__MODULE__, :pubkey)

  # --- GenServer Callbacks ---

  @impl true
  def init(_opts) do
    cfg = Application.get_env(:minted, :nostr, [])
    heartbeat_cfg = Keyword.get(cfg, :heartbeat, [])

    state = %{
      relays: Keyword.get(cfg, :relays, []),
      operator_pubkey: normalise_pubkey(Keyword.get(cfg, :operator_pubkey)),
      severities: Keyword.get(cfg, :alert_severities, @default_severities),
      signing_key: load_signing_key(),
      heartbeat_enabled: Keyword.get(heartbeat_cfg, :enabled, true),
      heartbeat_interval_ms: Keyword.get(heartbeat_cfg, :interval_ms, @default_heartbeat_interval_ms)
    }

    cond do
      is_nil(state.operator_pubkey) ->
        Logger.warning("Nostr: operator_pubkey not configured — alerts will not be published")

      state.relays == [] ->
        Logger.warning("Nostr: no relays configured — alerts will not be published")

      true ->
        EventBus.subscribe(TelemetryEvents.AlertFired)
        EventBus.subscribe(TelemetryEvents.AlertResolved)
        maybe_schedule_heartbeat(state)
        Logger.info("Nostr: subscribed, #{length(state.relays)} relay(s), heartbeat=#{heartbeat_log_label(state)}")
    end

    {:ok, state}
  end

  @impl true
  def handle_call(:pubkey, _from, %{signing_key: %{public_hex: hex}} = state) do
    {:reply, {:ok, hex}, state}
  end

  def handle_call(:pubkey, _from, state), do: {:reply, {:error, :not_available}, state}

  @impl true
  def handle_info(%TelemetryEvents.AlertFired{severity: severity} = event, state) do
    if severity in state.severities do
      dispatch_alert(format_fired(event), state)
    end

    {:noreply, state}
  end

  def handle_info(%TelemetryEvents.AlertResolved{} = event, state) do
    dispatch_alert(format_resolved(event), state)
    {:noreply, state}
  end

  def handle_info(:heartbeat, state) do
    maybe_schedule_heartbeat(state)
    dispatch_alert(format_heartbeat(), state)
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # --- Formatting ---

  @doc false
  def format_fired(%TelemetryEvents.AlertFired{} = event) do
    severity = Display.severity(event) |> to_string() |> String.upcase()
    detail = Display.detail(event)

    lines = ["#{prefix()} #{severity} #{Display.label(event)}"]
    lines = if detail != "", do: lines ++ [detail], else: lines
    lines = lines ++ ["at #{DateTime.to_iso8601(event.timestamp)}"]

    Enum.join(lines, "\n")
  end

  @doc false
  def format_resolved(%TelemetryEvents.AlertResolved{} = event) do
    detail = Display.detail(event)

    lines = ["#{prefix()} RESOLVED #{Display.label(event)}"]
    lines = if detail != "", do: lines ++ [detail], else: lines
    lines = lines ++ ["at #{DateTime.to_iso8601(event.timestamp)}"]

    Enum.join(lines, "\n")
  end

  @doc false
  def format_heartbeat do
    Enum.join(
      [
        "#{prefix()} HEARTBEAT",
        "at #{DateTime.utc_now() |> DateTime.to_iso8601()}"
      ],
      "\n"
    )
  end

  # Prefix carries the node identity so a single Nostr client can
  # tell prod alerts from staging alerts at a glance. NODE_LABEL env
  # is set from the inventory hostname suffix by Ansible (`N1`, `S1`).
  # Falls back to plain `[MINTED]` when unset (dev/test).
  defp prefix do
    case Application.get_env(:minted, :node_label) do
      nil -> "[MINTED]"
      "" -> "[MINTED]"
      label -> "[MINTED / #{label}]"
    end
  end

  # --- Heartbeat scheduling ---

  defp maybe_schedule_heartbeat(%{heartbeat_enabled: true, heartbeat_interval_ms: ms}) do
    Process.send_after(self(), :heartbeat, ms)
  end

  defp maybe_schedule_heartbeat(_state), do: :ok

  defp heartbeat_log_label(%{heartbeat_enabled: false}), do: "off"

  defp heartbeat_log_label(%{heartbeat_interval_ms: ms}) do
    hours = ms |> div(1000) |> div(3600)
    "every #{hours}h"
  end

  # --- Dispatch ---

  defp dispatch_alert(_plaintext, %{operator_pubkey: nil}), do: :ok
  defp dispatch_alert(_plaintext, %{relays: []}), do: :ok
  defp dispatch_alert(_plaintext, %{signing_key: nil}), do: :ok

  defp dispatch_alert(plaintext, state) do
    case build_gift_wrap(plaintext, state) do
      {:ok, gift_wrap} ->
        publish_to_relays(gift_wrap, state.relays)
        {:ok, gift_wrap.id}

      {:error, reason} ->
        Logger.warning("Nostr: failed to build gift wrap: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # --- NIP-17 gift-wrap construction ---

  @doc false
  def build_gift_wrap(plaintext, state) do
    with {:ok, rumor_json} <- build_rumor(plaintext, state),
         {:ok, seal_event} <- build_seal(rumor_json, state),
         {:ok, seal_json} <- json_encode_event(seal_event) do
      wrap_seal(seal_json, state)
    end
  end

  # Layer 1: rumor — kind 14, unsigned chat message. Only the JSON form is
  # needed for encryption; the rumor's id is computed but no signature is
  # produced (that's the whole point of the rumor).
  defp build_rumor(plaintext, state) do
    tags = [["p", state.operator_pubkey]]
    created_at = now_unix()
    sender_pubkey = state.signing_key.public_hex

    rumor = %{
      pubkey: sender_pubkey,
      created_at: created_at,
      kind: @kind_rumor,
      tags: tags,
      content: plaintext
    }

    id = event_id(rumor, sender_pubkey)
    rumor_with_id = Map.put(rumor, :id, id)

    case json_encode_event(rumor_with_id) do
      {:ok, json} -> {:ok, json}
      err -> err
    end
  end

  # Layer 2: seal — kind 13. Content is the NIP-44 encrypted rumor JSON.
  # Tags MUST be empty (per NIP-17). Signed by the sender's real key.
  defp build_seal(rumor_json, state) do
    with {:ok, ciphertext} <-
           Nip44.encrypt(rumor_json, state.signing_key.private, decode_hex32!(state.operator_pubkey)) do
      sender_pubkey = state.signing_key.public_hex
      created_at = jitter_timestamp()

      seal = %{
        pubkey: sender_pubkey,
        created_at: created_at,
        kind: @kind_seal,
        tags: [],
        content: ciphertext
      }

      id = event_id(seal, sender_pubkey)

      case sign_event(id, state.signing_key.private) do
        {:ok, sig} ->
          {:ok, Map.merge(seal, %{id: id, sig: sig})}

        {:error, reason} ->
          {:error, {:seal_sign_failed, reason}}
      end
    end
  end

  # Layer 3: gift wrap — kind 1059. Content is the NIP-44 encrypted seal JSON.
  # Signed by a fresh ephemeral key that is then discarded. Carries a p-tag so
  # the recipient can find it on the relay.
  defp wrap_seal(seal_json, state) do
    {ephemeral_priv, ephemeral_pub_hex} = generate_ephemeral_keypair()

    with {:ok, ciphertext} <-
           Nip44.encrypt(seal_json, ephemeral_priv, decode_hex32!(state.operator_pubkey)) do
      created_at = jitter_timestamp()

      wrap = %{
        pubkey: ephemeral_pub_hex,
        created_at: created_at,
        kind: @kind_gift_wrap,
        tags: [["p", state.operator_pubkey]],
        content: ciphertext
      }

      id = event_id(wrap, ephemeral_pub_hex)

      case sign_event(id, ephemeral_priv) do
        {:ok, sig} ->
          {:ok, Map.merge(wrap, %{id: id, sig: sig})}

        {:error, reason} ->
          {:error, {:wrap_sign_failed, reason}}
      end
    end
  end

  # --- Event id / signing / JSON ---

  defp event_id(event, pubkey_hex) do
    [0, pubkey_hex, event.created_at, event.kind, event.tags, event.content]
    |> Jason.encode!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp sign_event(event_id_hex, privkey) do
    id_bytes = Base.decode16!(event_id_hex, case: :lower)

    case Cashew.schnorr_sign(privkey, id_bytes) do
      {:ok, {signature, _xonly}} -> {:ok, Base.encode16(signature, case: :lower)}
      {:error, reason} -> {:error, reason}
    end
  end

  # Canonical NIP-01 event JSON: id/pubkey/created_at/kind/tags/content and
  # (for signed events) sig. Field order is not strictly canonical in NIP-01
  # but Jason produces stable output which is sufficient here since this JSON
  # is only consumed by our own encryption pipeline.
  defp json_encode_event(event) do
    {:ok, Jason.encode!(event)}
  rescue
    e ->
      Logger.error("Nostr: JSON encode crashed", crash_reason: {e, __STACKTRACE__})
      {:error, :json_encode_failed}
  end

  # --- Timestamps ---

  defp now_unix, do: System.system_time(:second)

  # NIP-59: seal and gift-wrap timestamps should be randomised within the
  # past 2 days to prevent timing correlation between related events.
  # Uses :crypto.strong_rand_bytes (not :rand) — the jitter is privacy-
  # critical metadata and a predictable PRNG would let a passive relay
  # observer reconstruct the real emission time after a few samples.
  defp jitter_timestamp do
    <<n::unsigned-32>> = :crypto.strong_rand_bytes(4)
    now_unix() - rem(n, @timestamp_jitter_seconds) - 1
  end

  # --- Ephemeral key generation (for gift wrap) ---

  defp generate_ephemeral_keypair do
    {:ok, {priv, pub}} = Cashew.generate_keypair()
    <<_prefix::8, xonly::binary-32>> = pub
    {priv, Base.encode16(xonly, case: :lower)}
  end

  # --- Relay publishing ---

  # Dialyzer can't see through Mint.WebSocket's opaque return types in
  # Relay.Client.publish/2; suppress call-site pattern_match warnings.
  @dialyzer {:nowarn_function, publish_to_relays: 2}

  defp publish_to_relays(event, relays) do
    Enum.each(relays, fn relay_url ->
      case Minted.Nostr.Relay.Client.publish(relay_url, event) do
        {:error, reason} ->
          Logger.warning("Nostr: publish failed #{relay_url}: #{inspect(reason)}")

        _ok ->
          Logger.info("Nostr: published #{event.id} to #{relay_url}")
      end
    end)
  end

  # --- Recipient pubkey handling ---

  defp normalise_pubkey(nil), do: nil

  defp normalise_pubkey(hex) when is_binary(hex) do
    if byte_size(hex) == 64 and String.match?(hex, ~r/^[0-9a-fA-F]+$/) do
      String.downcase(hex)
    else
      Logger.warning("Nostr: operator_pubkey must be 64-char hex x-only pubkey")
      nil
    end
  end

  defp decode_hex32!(hex) do
    {:ok, <<_::binary-32>> = bin} = Base.decode16(hex, case: :mixed)
    bin
  end

  # --- Key loading ---

  defp load_signing_key do
    path = Minted.Storage.Paths.key_file(@key_label)

    with {:ok, encrypted} <- File.read(path),
         {:ok, <<privkey::binary-32, xonly::binary-32>>} <-
           Minted.Storage.Facade.decrypt(encrypted) do
      %{
        private: privkey,
        xonly: xonly,
        public_hex: Base.encode16(xonly, case: :lower)
      }
    else
      _ ->
        Logger.error("Nostr: signing key unavailable — alerts will not be published")
        nil
    end
  rescue
    _ ->
      Logger.error("Nostr: signing key unavailable — alerts will not be published")
      nil
  end

  # Redact signing key from crash dumps and :sys.get_state/1.
  @impl true
  def format_status(_reason, [pdict, state]) do
    redacted = %{state | signing_key: :redacted}
    [{:data, [{"State", redacted}]} | pdict]
  end
end
