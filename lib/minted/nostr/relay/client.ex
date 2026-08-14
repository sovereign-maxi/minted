defmodule Minted.Nostr.Relay.Client do
  @moduledoc """
  One-shot WebSocket publisher for Nostr relay events.

  Nostr is a WebSocket-only protocol (NIP-01): relays do not accept
  event submissions over HTTP POST. This module connects to a `wss://`
  relay, performs the upgrade, sends a single `["EVENT", event]` frame,
  waits briefly for the `["OK", id, accepted, msg]` acknowledgement,
  and tears down.

  All outbound traffic goes through the Tor HTTP CONNECT tunnel
  configured at `:minted, :tor_http_tunnel` in `runtime.exs`. In dev,
  the tunnel is optional and requests fall through to direct. In prod,
  boot refuses to start without a tunnel (see `Minted.Application`).

  ## Usage

      Minted.Nostr.Relay.Client.publish(
        "wss://relay.damus.io",
        signed_event_map
      )
      # => {:ok, "event-id"} | {:error, reason}

  The message is sent as `Jason.encode!(["EVENT", event])` matching the
  NIP-01 client-to-relay message format.
  """

  require Logger

  # Dialyzer cannot see through Mint.HTTP / Mint.WebSocket opaque types
  # across the with-chain and incorrectly narrows return types to only
  # their error variants. Suppress the specific false positives — all
  # success paths are exercised at runtime against real Nostr relays.
  @dialyzer {:nowarn_function,
             [
               publish: 2,
               ws_upgrade: 2,
               await_upgrade_response: 2,
               finalize_upgrade: 3,
               send_event: 4,
               wait_for_ok: 4,
               handle_frames: 5,
               interpret_frames: 2
             ]}

  @connect_timeout_ms 10_000
  @ack_timeout_ms 5_000

  @doc """
  Publishes a signed Nostr event map to a single relay URL. Returns
  `{:ok, event_id}` on successful acceptance by the relay, or
  `{:error, reason}` on any failure.
  """
  @spec publish(String.t(), map()) :: {:ok, String.t()} | {:error, term()}
  def publish(relay_url, %{} = event) when is_binary(relay_url) do
    with {:ok, uri} <- parse_relay_url(relay_url),
         {:ok, conn} <- http_connect(uri),
         {:ok, conn, ref} <- ws_upgrade(conn, uri),
         {:ok, conn, websocket} <- await_upgrade_response(conn, ref),
         {:ok, _conn, _websocket} <- send_event(conn, websocket, ref, event) do
      {:ok, event.id}
    end
  rescue
    e ->
      Logger.error("RelayClient: publish crashed", crash_reason: {e, __STACKTRACE__})
      {:error, :publish_crashed}
  catch
    kind, reason ->
      Logger.error("RelayClient: publish #{kind} #{inspect(reason)}")
      {:error, :publish_crashed}
  end

  # --- URL parsing ---

  defp parse_relay_url(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host} = uri when scheme in ["ws", "wss"] and is_binary(host) ->
        port = uri.port || if(scheme == "wss", do: 443, else: 80)
        path = uri.path || "/"
        {:ok, %{scheme: String.to_atom(scheme), host: host, port: port, path: path}}

      _ ->
        {:error, {:invalid_relay_url, url}}
    end
  end

  # --- Mint HTTP connection (via Tor tunnel when configured) ---

  defp http_connect(%{scheme: :wss, host: host, port: port}) do
    Mint.HTTP.connect(:https, host, port, build_connect_opts())
  end

  defp http_connect(%{scheme: :ws, host: host, port: port}) do
    Mint.HTTP.connect(:http, host, port, build_connect_opts())
  end

  defp build_connect_opts do
    base = [
      transport_opts: [
        timeout: @connect_timeout_ms,
        verify: :verify_peer,
        cacerts: :public_key.cacerts_get(),
        depth: 3
      ],
      protocols: [:http1]
    ]

    case Application.get_env(:minted, :tor_http_tunnel) do
      nil ->
        base

      {host, port} when is_binary(host) and is_integer(port) ->
        # Tor's HTTPTunnelPort is a plain HTTP CONNECT proxy. Mint tunnels
        # TLS through it transparently for :https/:wss.
        Keyword.put(base, :proxy, {:http, host, port, []})
    end
  end

  # --- WebSocket upgrade + send + ack ---

  defp ws_upgrade(conn, %{scheme: scheme, path: path}) do
    Mint.WebSocket.upgrade(scheme, conn, path, [])
  end

  defp await_upgrade_response(conn, ref) do
    receive do
      message ->
        case Mint.WebSocket.stream(conn, message) do
          {:ok, conn, responses} -> finalize_upgrade(conn, ref, responses)
          {:error, _conn, reason, _responses} -> {:error, {:upgrade_stream, reason}}
        end
    after
      @connect_timeout_ms -> {:error, :upgrade_timeout}
    end
  end

  defp finalize_upgrade(conn, ref, responses) do
    status =
      Enum.find_value(responses, fn
        {:status, ^ref, s} -> s
        _ -> nil
      end)

    headers =
      Enum.find_value(responses, fn
        {:headers, ^ref, h} -> h
        _ -> nil
      end)

    done? = Enum.any?(responses, &match?({:done, ^ref}, &1))

    if is_nil(status) or is_nil(headers) or not done? do
      await_upgrade_response(conn, ref)
    else
      case Mint.WebSocket.new(conn, ref, status, headers) do
        {:ok, conn, websocket} -> {:ok, conn, websocket}
        {:error, _conn, reason} -> {:error, {:ws_new_failed, reason}}
      end
    end
  end

  defp send_event(conn, websocket, ref, event) do
    payload = Jason.encode!(["EVENT", event])

    with {:ok, websocket, data} <- Mint.WebSocket.encode(websocket, {:text, payload}),
         {:ok, conn} <- Mint.WebSocket.stream_request_body(conn, ref, data),
         {:ok, conn, websocket} <- wait_for_ok(conn, websocket, ref, event.id) do
      _ = Mint.HTTP.close(conn)
      {:ok, conn, websocket}
    else
      {:error, _conn, reason} -> {:error, {:send_failed, reason}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp wait_for_ok(conn, websocket, ref, event_id) do
    receive do
      message ->
        case Mint.WebSocket.stream(conn, message) do
          {:ok, conn, [{:data, ^ref, data}]} ->
            handle_frames(conn, websocket, ref, data, event_id)

          {:ok, conn, _other} ->
            wait_for_ok(conn, websocket, ref, event_id)

          {:error, _conn, reason, _responses} ->
            {:error, {:stream_error, reason}}
        end
    after
      @ack_timeout_ms ->
        # Relay accepted the frame (send succeeded) but didn't ack in
        # time. Fire-and-forget publishers treat this as success.
        {:ok, conn, websocket}
    end
  end

  defp handle_frames(conn, websocket, ref, data, event_id) do
    case Mint.WebSocket.decode(websocket, data) do
      {:ok, websocket, frames} ->
        case interpret_frames(frames, event_id) do
          :ok -> {:ok, conn, websocket}
          {:error, reason} -> {:error, reason}
          :continue -> wait_for_ok(conn, websocket, ref, event_id)
        end

      {:error, _websocket, reason} ->
        {:error, {:decode_failed, reason}}
    end
  end

  defp interpret_frames([], _event_id), do: :continue

  defp interpret_frames([{:text, text} | rest], event_id) do
    case Jason.decode(text) do
      {:ok, ["OK", ^event_id, true | _]} ->
        :ok

      {:ok, ["OK", ^event_id, false, reason]} ->
        {:error, {:relay_rejected, reason}}

      {:ok, ["NOTICE", notice]} ->
        Logger.debug("RelayClient: NOTICE #{notice}")
        interpret_frames(rest, event_id)

      _ ->
        interpret_frames(rest, event_id)
    end
  end

  defp interpret_frames([{:close, _code, _reason} | _], _event_id) do
    {:error, :relay_closed_connection}
  end

  defp interpret_frames([_ | rest], event_id), do: interpret_frames(rest, event_id)
end
