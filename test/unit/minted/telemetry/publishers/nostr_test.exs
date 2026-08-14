defmodule Minted.Telemetry.Publishers.NostrTest do
  @moduledoc "Unit tests for Minted.Telemetry.Publishers.Nostr."

  use ExUnit.Case, async: true

  alias Minted.Events.Telemetry, as: TelemetryEvents
  alias Minted.Telemetry.Publishers.Nostr, as: Publisher
  alias Minted.Telemetry.Publishers.Nostr.Nip44

  describe "format_fired/1" do
    test "includes severity, humanised name, reason, and timestamp" do
      event = %TelemetryEvents.AlertFired{
        name: :reserve_ratio_low,
        domain: "Reserves",
        severity: :critical,
        reason: "ratio=87.0%",
        timestamp: ~U[2026-04-05 12:00:00Z]
      }

      out = Publisher.format_fired(event)

      assert out =~ "[MINTED] CRITICAL Reserve Ratio Low"
      assert out =~ "ratio=87.0%"
      assert out =~ "2026-04-05T12:00:00Z"
    end

    test "uses Display protocol severity" do
      event = %TelemetryEvents.AlertFired{
        name: :cpu_high,
        domain: "System",
        severity: :warning,
        reason: "usage=85.0%, threshold=80%",
        timestamp: ~U[2026-04-05 00:00:00Z]
      }

      assert Publisher.format_fired(event) =~ "[MINTED] WARNING Cpu High"
    end

    test "prefix carries node label when :node_label is configured" do
      Application.put_env(:minted, :node_label, "N1")

      on_exit(fn -> Application.delete_env(:minted, :node_label) end)

      event = %TelemetryEvents.AlertFired{
        name: :cpu_high,
        domain: "System",
        severity: :warning,
        reason: "usage=85%",
        timestamp: ~U[2026-04-05 00:00:00Z]
      }

      assert Publisher.format_fired(event) =~ "[MINTED / N1] WARNING Cpu High"
    end
  end

  describe "format_resolved/1" do
    test "formats resolved message with humanised name and status" do
      event = %TelemetryEvents.AlertResolved{
        name: :reserve_ratio_low,
        domain: "Reserves",
        timestamp: ~U[2026-04-05 13:00:00Z]
      }

      out = Publisher.format_resolved(event)

      assert out =~ "[MINTED] RESOLVED Reserve Ratio Low"
      assert out =~ "status=resolved"
      assert out =~ "2026-04-05T13:00:00Z"
    end

    test "resolved message is clean without firing detail" do
      event = %TelemetryEvents.AlertResolved{
        name: :backup_overdue,
        domain: "Mint",
        detail: "last_backup=5m",
        timestamp: ~U[2026-04-05 13:00:00Z]
      }

      out = Publisher.format_resolved(event)

      assert out =~ "[MINTED] RESOLVED Backup Overdue"
      assert out =~ "status=resolved"
      assert out =~ "2026-04-05T13:00:00Z"
      refute out =~ "last_backup=5m"
    end

    test "resolved prefix carries node label when :node_label is configured" do
      Application.put_env(:minted, :node_label, "N1")
      on_exit(fn -> Application.delete_env(:minted, :node_label) end)

      event = %TelemetryEvents.AlertResolved{
        name: :backup_overdue,
        domain: "Mint",
        timestamp: ~U[2026-04-05 13:00:00Z]
      }

      assert Publisher.format_resolved(event) =~ "[MINTED / N1] RESOLVED Backup Overdue"
    end
  end

  describe "format_heartbeat/0" do
    test "includes the HEARTBEAT keyword + a UTC timestamp" do
      out = Publisher.format_heartbeat()

      assert out =~ "[MINTED] HEARTBEAT"
      assert out =~ ~r/at \d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}/
    end

    test "prefix carries node label when :node_label is configured" do
      Application.put_env(:minted, :node_label, "S1")
      on_exit(fn -> Application.delete_env(:minted, :node_label) end)

      assert Publisher.format_heartbeat() =~ "[MINTED / S1] HEARTBEAT"
    end
  end

  describe "NIP-44 padding (spec vectors)" do
    # Spec vectors from the NIP-44 reference implementation
    # (https://github.com/paulmillr/nip44). Small inputs pad to 32,
    # larger inputs follow the bucket scheme.
    @padding_vectors [
      {16, 32},
      {32, 32},
      {33, 64},
      {45, 64},
      {49, 64},
      {64, 64},
      {65, 96},
      {100, 128},
      {111, 128},
      {200, 224},
      {250, 256},
      {320, 320},
      {383, 384},
      {384, 384},
      {400, 448},
      {500, 512},
      {512, 512},
      {515, 640},
      {700, 768},
      {800, 896},
      {900, 1024},
      {1020, 1024}
    ]

    for {input, expected} <- @padding_vectors do
      test "calc_padded_len(#{input}) == #{expected}" do
        assert Nip44.calc_padded_len(unquote(input)) == unquote(expected)
      end
    end
  end

  describe "NIP-44 encryption" do
    setup do
      {:ok, {sender_priv, sender_pub}} = Cashew.generate_keypair()
      {:ok, {_recv_priv, recv_pub}} = Cashew.generate_keypair()

      <<_::8, sender_xonly::binary-32>> = sender_pub
      <<_::8, recv_xonly::binary-32>> = recv_pub

      %{sender_priv: sender_priv, sender_xonly: sender_xonly, recipient: recv_xonly}
    end

    test "encrypts short plaintext", %{sender_priv: priv, recipient: recipient} do
      assert {:ok, payload} = Nip44.encrypt("hello", priv, recipient)
      assert is_binary(payload)
      assert {:ok, raw} = Base.decode64(payload)

      # v2 payload = version(1) + nonce(32) + ciphertext + mac(32)
      # Shortest ciphertext is 2-byte length prefix + 32 padded = 34 bytes
      assert byte_size(raw) == 1 + 32 + 34 + 32
      <<version::8, _::binary>> = raw
      assert version == 2
    end

    test "different plaintexts produce different ciphertexts", %{sender_priv: priv, recipient: recipient} do
      {:ok, a} = Nip44.encrypt("first alert", priv, recipient)
      {:ok, b} = Nip44.encrypt("second alert", priv, recipient)
      refute a == b
    end

    test "same plaintext produces different ciphertexts (random nonce)", %{sender_priv: priv, recipient: recipient} do
      {:ok, a} = Nip44.encrypt("alert", priv, recipient)
      {:ok, b} = Nip44.encrypt("alert", priv, recipient)
      refute a == b
    end

    test "rejects empty plaintext", %{sender_priv: priv, recipient: recipient} do
      assert {:error, :plaintext_too_short} = Nip44.encrypt("", priv, recipient)
    end

    test "rejects oversized plaintext", %{sender_priv: priv, recipient: recipient} do
      huge = String.duplicate("x", 70_000)
      assert {:error, :plaintext_too_long} = Nip44.encrypt(huge, priv, recipient)
    end

    test "rejects wrong-sized private key", %{recipient: recipient} do
      assert {:error, :invalid_privkey} = Nip44.encrypt("hi", <<0::248>>, recipient)
    end

    test "rejects wrong-sized recipient pubkey", %{sender_priv: priv} do
      assert {:error, :invalid_recipient} = Nip44.encrypt("hi", priv, <<0::128>>)
    end

    test "pad/1 uses length prefix + plaintext + zero-fill" do
      padded = Nip44.pad("abc")
      # length prefix (2 bytes BE) + 32 bucket = 34 bytes total
      assert byte_size(padded) == 34
      assert <<0, 3, "abc", _rest::binary>> = padded
    end
  end

  describe "NIP-17 gift wrap" do
    setup do
      {:ok, {sender_priv, sender_pub}} = Cashew.generate_keypair()
      <<_::8, sender_xonly::binary-32>> = sender_pub

      signing_key = %{
        private: sender_priv,
        xonly: sender_xonly,
        public_hex: Base.encode16(sender_xonly, case: :lower)
      }

      {:ok, {_recv_priv, recv_pub}} = Cashew.generate_keypair()
      <<_::8, recv_xonly::binary-32>> = recv_pub

      state = %{
        signing_key: signing_key,
        operator_pubkey: Base.encode16(recv_xonly, case: :lower),
        relays: [],
        severities: [:critical, :warning]
      }

      %{state: state}
    end

    test "produces a kind-1059 gift wrap", %{state: state} do
      {:ok, wrap} = Publisher.build_gift_wrap("critical alert", state)

      assert wrap.kind == 1059
      assert [["p", recipient]] = wrap.tags
      assert recipient == state.operator_pubkey
      assert byte_size(wrap.id) == 64
      assert byte_size(wrap.sig) == 128
      assert byte_size(wrap.pubkey) == 64
    end

    test "gift wrap pubkey is NOT the signing key (ephemeral key used)", %{state: state} do
      {:ok, wrap} = Publisher.build_gift_wrap("secret alert", state)
      refute wrap.pubkey == state.signing_key.public_hex
    end

    test "each gift wrap uses a fresh ephemeral key", %{state: state} do
      {:ok, a} = Publisher.build_gift_wrap("msg", state)
      {:ok, b} = Publisher.build_gift_wrap("msg", state)
      refute a.pubkey == b.pubkey
    end

    test "gift wrap signature verifies against its event id", %{state: state} do
      {:ok, wrap} = Publisher.build_gift_wrap("verify me", state)

      id_bytes = Base.decode16!(wrap.id, case: :lower)
      sig_bytes = Base.decode16!(wrap.sig, case: :lower)
      xonly = Base.decode16!(wrap.pubkey, case: :lower)

      assert :ok = Cashew.schnorr_verify(xonly, id_bytes, sig_bytes)
    end

    test "gift wrap content is valid NIP-44 base64 payload", %{state: state} do
      {:ok, wrap} = Publisher.build_gift_wrap("payload check", state)

      assert {:ok, raw} = Base.decode64(wrap.content)
      # v2 header
      <<version::8, _rest::binary>> = raw
      assert version == 2
      # Minimum size: 1 (version) + 32 (nonce) + 34 (2-byte len + 32 padding) + 32 (mac)
      # The seal JSON is much larger so we just sanity-check the lower bound
      assert byte_size(raw) > 1 + 32 + 34 + 32
    end

    test "gift wrap timestamp is in the past (randomised)", %{state: state} do
      now = System.system_time(:second)
      {:ok, wrap} = Publisher.build_gift_wrap("time check", state)

      # Jittered backward by up to 2 days
      assert wrap.created_at < now
      assert wrap.created_at >= now - 2 * 24 * 60 * 60 - 1
    end
  end
end
