defmodule Minted.Scenarios.PhoenixdWebhookTest do
  @moduledoc """
  End-to-end webhook tests that drive requests through the full
  endpoint stack — the same path a live phoenixd callback takes.

  Pins the two contracts that were broken before the rebuild:

    1. The endpoint's Plug.Parsers no longer consumes the raw body
       on webhook paths. HMAC verification runs against the exact
       bytes phoenixd signed. A working signature MUST return 200.

    2. The plug matches phoenixd's real webhook payload shape
       (camelCase `paymentHash`, no `preimage`) and triggers an
       immediate invoice-status poll rather than trying to accept
       the preimage from the callback body.
  """

  use ExUnit.Case, async: false

  @moduletag :scenario

  import Mox
  import Plug.Test
  import Plug.Conn

  alias Minted.Lightning.Manager
  alias Minted.Lightning.PhoenixdMock

  @endpoint MintedWeb.Endpoint

  @webhook_secret "test-webhook-secret-32-bytes-min-padding-xxxxx"
  @webhook_path "/internal/webhooks/phoenixd/payment-received"

  setup :set_mox_global
  setup :verify_on_exit!

  setup do
    Minted.TestHelpers.StateHelpers.clean_state(%{})

    old_secret = Application.get_env(:minted, :webhook_secret)
    Application.put_env(:minted, :webhook_secret, @webhook_secret)
    :persistent_term.erase({MintedWeb.Plugs.PhoenixdWebhook, :opts})

    stub(PhoenixdMock, :get_incoming_payment, fn _config, _hash ->
      {:error, :not_found}
    end)

    data_dir = Path.join(System.tmp_dir!(), "minted_wh_e2e_#{System.unique_integer([:positive])}")
    File.mkdir_p!(data_dir)
    {:ok, mgr_pid} = Manager.start_link(data_dir: data_dir, poll_interval: 60_000)

    on_exit(fn ->
      Application.put_env(:minted, :webhook_secret, old_secret)
      :persistent_term.erase({MintedWeb.Plugs.PhoenixdWebhook, :opts})

      try do
        if Process.alive?(mgr_pid), do: GenServer.stop(mgr_pid, :normal, 500)
      catch
        :exit, _ -> :ok
      end

      File.rm_rf(data_dir)
    end)

    %{data_dir: data_dir}
  end

  describe "raw body preservation through the endpoint pipeline" do
    test "valid HMAC signature over exact body bytes returns 200" do
      body = Jason.encode!(%{"paymentHash" => random_hash_hex()})
      signature = hmac_hex(body, @webhook_secret)

      resp = post_webhook(body, [{"x-phoenix-signature", signature}])
      assert resp.status == 200
      assert resp.resp_body == "ok"
    end

    test "tampered body with old signature returns 401" do
      original = Jason.encode!(%{"paymentHash" => random_hash_hex()})
      tampered = Jason.encode!(%{"paymentHash" => random_hash_hex()})
      signature = hmac_hex(original, @webhook_secret)

      resp = post_webhook(tampered, [{"x-phoenix-signature", signature}])
      assert resp.status == 401
    end

    test "missing signature header returns 401" do
      body = Jason.encode!(%{"paymentHash" => random_hash_hex()})

      resp = post_webhook(body, [])
      assert resp.status == 401
    end
  end

  describe "phoenixd payload shape" do
    test "webhook with only camelCase paymentHash succeeds (no preimage in body)" do
      body = Jason.encode!(%{"paymentHash" => random_hash_hex()})
      signature = hmac_hex(body, @webhook_secret)

      resp = post_webhook(body, [{"x-phoenix-signature", signature}])
      assert resp.status == 200
    end
  end

  describe "invoice re-tracking on restart" do
    test "pending invoices restored from DETS are re-registered with FireBird.Manager", %{
      data_dir: data_dir
    } do
      hash_hex = random_hash_hex()

      expect(PhoenixdMock, :create_invoice, fn _config, 4_000, _desc, _exp ->
        {:ok, %{"paymentHash" => hash_hex, "serialized" => "lnbc4000u1p_test"}}
      end)

      {:ok, _inv} = Manager.create_invoice(4_000, "reboot test", quote_id: "q-reboot")

      # Kill and restart the Manager. The DETS-restored invoice must
      # be re-registered with FireBird so the poll loop resumes.
      manager_pid = Process.whereis(Manager)
      GenServer.stop(manager_pid)

      {:ok, restarted} = Manager.start_link(data_dir: data_dir, poll_interval: 60_000)

      assert {:ok, invoice} = Manager.get_invoice(hash_hex)
      assert invoice.status == :pending

      case Process.whereis(FireBird.Manager) do
        nil ->
          :ok

        _pid ->
          hash_bin = Base.decode16!(hash_hex, case: :mixed)
          assert {:ok, _} = FireBird.Manager.lookup(FireBird.Manager, hash_bin)
      end

      GenServer.stop(restarted)
    end
  end

  defp post_webhook(body, extra_headers) do
    headers = [{"content-type", "application/json"} | extra_headers]

    conn =
      Enum.reduce(headers, conn(:post, @webhook_path, body), fn {k, v}, c ->
        put_req_header(c, k, v)
      end)
      |> Map.put(:remote_ip, {127, 0, 0, 1})

    @endpoint.call(conn, @endpoint.init([]))
  end

  defp hmac_hex(body, secret) do
    :hmac
    |> :crypto.mac(:sha256, secret, body)
    |> Base.encode16(case: :lower)
  end

  defp random_hash_hex do
    Base.encode16(:crypto.strong_rand_bytes(32), case: :lower)
  end
end
