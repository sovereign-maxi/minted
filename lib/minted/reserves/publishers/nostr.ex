defmodule Minted.Reserves.Publishers.Nostr do
  @moduledoc """
  Publishes reserve proofs as NIP-33 replaceable Nostr events (kind 30078).

  Signs events with a secp256k1 key stored via encrypted key files.
  Publishes to configured Nostr relays via HTTP POST.
  """

  use GenServer

  require Logger

  alias Minted.Storage.Facade, as: StorageFacade
  alias Minted.Storage.Paths

  @kind 30_078
  @key_label "nostr_signing_key"

  # Domain separator for the d-tag hash — prevents the derived value
  # from colliding with any other hash-of-pubkey construction this
  # codebase might grow. Baked into compile-time state only; never on
  # the wire.
  @d_tag_domain "minted-reserves-d-tag-v1:"

  @doc """
  Returns the NIP-33 `d` tag for a single proof cycle published by
  the node with the given pubkey at the given unix timestamp.

  The tag is derived from `pubkey || captured_at_unix` with a
  compile-time domain separator. Distinct timestamps yield distinct
  d-tags, so each cycle becomes its own addressable event on Nostr.
  Without the per-cycle bind, NIP-33's replaceable semantic would
  have each new event supersede the prior one and Nostr would only
  ever carry the latest proof — the historical archive (which is
  the whole point of off-server publication) would be eroded.

  Discovery: clients enumerate the publisher's proofs via a
  `kind:30078, authors: [pubkey]` filter on a relay; each event's
  own `created_at` and `d` tag identify the cycle.
  """
  @spec d_tag(binary(), integer()) :: String.t()
  def d_tag(pubkey_hex, captured_at_unix)
      when is_binary(pubkey_hex) and is_integer(captured_at_unix) do
    input = @d_tag_domain <> pubkey_hex <> ":" <> Integer.to_string(captured_at_unix)

    :sha256
    |> :crypto.hash(input)
    |> Base.encode16(case: :lower)
    |> String.slice(0, 16)
  end

  # --- Public API ---

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @spec publish_vault_proof(Vault.Proof.t()) :: {:ok, String.t()} | {:error, term()}
  def publish_vault_proof(%Vault.Proof{} = proof) do
    GenServer.call(__MODULE__, {:publish_vault, proof})
  end

  @spec pubkey() :: {:ok, String.t()} | {:error, :not_available}
  def pubkey do
    GenServer.call(__MODULE__, :pubkey)
  end

  # --- GenServer Callbacks ---

  @impl true
  def init(_opts) do
    relays = Application.get_env(:minted, :nostr_relays, [])
    signing_key = load_or_generate_key()

    if relays != [] do
      Logger.info("Nostr: #{length(relays)} relay(s) configured")
    end

    {:ok,
     %{
       relays: relays,
       last_event_id: nil,
       signing_key: signing_key,
       events: []
     }}
  end

  @impl true
  def handle_call(:pubkey, _from, %{signing_key: %{public_hex: hex}} = state) do
    {:reply, {:ok, hex}, state}
  end

  def handle_call(:pubkey, _from, state) do
    {:reply, {:error, :not_available}, state}
  end

  @impl true
  def handle_call({:publish_vault, proof}, _from, state) do
    case build_signed_event(proof, state.signing_key) do
      {:ok, signed_event} ->
        Logger.info(
          "Nostr: event prepared: id=#{signed_event.id}, kind=#{@kind}, " <>
            "pubkey=#{String.slice(signed_event.pubkey, 0, 16)}..."
        )

        # Relay publishes go out over Tor and can be slow or stall on a
        # degraded circuit. Spawn an unlinked task so the caller (Vault.Generator)
        # gets an immediate reply with the built event id, and the actual
        # relay delivery happens in the background. Per-relay errors are
        # logged inside publish_to_relays/2.
        spawn(fn -> publish_to_relays(signed_event, state.relays) end)

        updated_events = Enum.take([signed_event | state.events], 100)

        {:reply, {:ok, signed_event.id}, %{state | last_event_id: signed_event.id, events: updated_events}}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  # --- Key Management ---

  # Three outcomes:
  #
  # - File missing (`:not_found`) — legitimate first-run, mint a
  #   fresh key and persist.
  # - File present and decrypts cleanly — adopt the existing identity.
  # - Anything else (decrypt failed, malformed binary, IO error) —
  #   refuse to start. Silently regenerating would replace the
  #   published Nostr identity that historical proofs are
  #   verifiable against, and an attacker with brief filesystem
  #   write access could force the rotation by corrupting one byte.
  #   Halting forces operator attention.
  defp load_or_generate_key do
    case load_key_file(@key_label) do
      {:ok, key_data} ->
        case deserialize_key(key_data) do
          {:ok, key} ->
            key

          {:error, reason} ->
            raise "Nostr: refusing to start — stored signing key is malformed (#{inspect(reason)}). " <>
                    "Investigate before clearing the key file; rotating identity here breaks " <>
                    "verification of every historical reserve proof."
        end

      {:error, :not_found} ->
        generate_and_store_key()

      {:error, reason} ->
        raise "Nostr: refusing to start — could not load signing key (#{inspect(reason)}). " <>
                "If the key file is present but unreadable, the operator must investigate " <>
                "rather than have the node silently mint a new identity."
    end
  end

  defp generate_and_store_key do
    key = generate_key()

    case store_key_file(@key_label, serialize_key(key)) do
      :ok ->
        Logger.info("Nostr: generated and stored signing key, pubkey=#{key.public_hex}")
        key

      {:error, reason} ->
        raise "Nostr: refusing to start — could not persist freshly generated signing key " <>
                "(#{inspect(reason)})"
    end
  end

  defp generate_key do
    {:ok, {privkey, pubkey}} = Cashew.generate_keypair()
    <<_prefix::8, xonly::binary-32>> = pubkey

    %{
      private: privkey,
      public: pubkey,
      xonly: xonly,
      public_hex: Base.encode16(xonly, case: :lower)
    }
  end

  defp serialize_key(key) do
    key.private <> key.xonly
  end

  defp deserialize_key(<<privkey::binary-32, xonly::binary-32>>) do
    case Cashew.pubkey_from_privkey(privkey) do
      {:ok, pubkey} ->
        {:ok,
         %{
           private: privkey,
           public: pubkey,
           xonly: xonly,
           public_hex: Base.encode16(xonly, case: :lower)
         }}

      {:error, reason} ->
        {:error, {:pubkey_derivation_failed, reason}}
    end
  end

  defp deserialize_key(_other), do: {:error, :malformed_key_file}

  # --- Event Building ---

  defp build_signed_event(%Vault.Proof{snapshot: snap} = proof, signing_key) do
    timestamp = DateTime.to_unix(snap.captured_at)
    epoch_id = Map.get(snap.metadata, :epoch_id, 0)

    content =
      Jason.encode!(%{
        epoch_id: epoch_id,
        reserve_ratio: format_ratio(snap.reserve_ratio),
        total_held: snap.total_held,
        outstanding: snap.outstanding,
        attestation_count: map_size(proof.attestations),
        asset_ids: snap.asset_ids,
        captured_at: DateTime.to_iso8601(snap.captured_at)
      })

    tags = [
      ["d", d_tag(signing_key.public_hex, timestamp)],
      ["t", "proof-of-reserves"],
      ["epoch", to_string(epoch_id)],
      ["ratio", format_ratio(snap.reserve_ratio)]
    ]

    event = %{kind: @kind, content: content, tags: tags, created_at: timestamp}
    pubkey = signing_key.public_hex
    id = event_id(event, pubkey)

    case sign_event(id, signing_key) do
      {:ok, signature} ->
        {:ok,
         %{
           id: id,
           pubkey: pubkey,
           created_at: event.created_at,
           kind: event.kind,
           tags: event.tags,
           content: event.content,
           sig: signature
         }}

      {:error, reason} ->
        {:error, {:signing_failed, reason}}
    end
  end

  defp event_id(event, pubkey) do
    Jason.encode!([0, pubkey, event.created_at, event.kind, event.tags, event.content])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp sign_event(event_id_hex, signing_key) do
    event_id_bytes = Base.decode16!(event_id_hex, case: :lower)

    case Cashew.schnorr_sign(signing_key.private, event_id_bytes) do
      {:ok, {signature, _xonly}} ->
        {:ok, Base.encode16(signature, case: :lower)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # --- Relay Publishing ---

  # Dialyzer can't see through Mint.WebSocket's opaque return types in
  # Relay.Client.publish/2 and narrows the return to its error variants.
  # Suppress the call-site pattern_match warnings — success paths are
  # exercised against real Nostr relays at runtime.
  @dialyzer {:nowarn_function, publish_to_relays: 2}

  defp publish_to_relays(_event, []), do: :ok

  defp publish_to_relays(event, relays) do
    Enum.each(relays, fn relay_url ->
      case Minted.Nostr.Relay.Client.publish(relay_url, event) do
        {:error, reason} ->
          Logger.warning("Nostr: failed to publish to #{relay_url}: #{inspect(reason)}")

        _ok ->
          Logger.info("Nostr: published event, id=#{event.id}, relay=#{relay_url}")
      end
    end)
  end

  defp format_ratio(:infinity), do: "infinity"
  defp format_ratio(ratio) when is_number(ratio), do: Float.to_string(Float.round(ratio * 1.0, 6))

  # --- Encrypted key file helpers ---

  defp load_key_file(label) do
    path = Paths.key_file(label)

    with {:ok, encrypted} <- File.read(path),
         {:ok, plaintext} <- StorageFacade.decrypt(encrypted) do
      {:ok, plaintext}
    else
      {:error, :enoent} -> {:error, :not_found}
      error -> error
    end
  end

  defp store_key_file(label, data) do
    path = Paths.key_file(label)
    File.mkdir_p!(Path.dirname(path))

    with {:ok, encrypted} <- StorageFacade.encrypt(data),
         :ok <- File.write(path, encrypted) do
      # Belt-and-braces — the parent dir is 0o700 already, but a
      # permissive umask or a backup tool that re-creates files
      # would leave the file mode dependent on environment.
      File.chmod(path, 0o600)
    end
  end

  # Redact signing key from crash dumps and :sys.get_state/1.
  @impl true
  def format_status(_reason, [pdict, state]) do
    redacted = %{state | signing_key: :redacted}
    [{:data, [{"State", redacted}]} | pdict]
  end
end
