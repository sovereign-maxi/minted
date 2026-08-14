defmodule MintedWeb.Plugs.ConditionalBodyParser do
  @moduledoc """
  Wraps `Plug.Parsers`, skipping it for paths that need the raw
  request body intact (webhooks). The endpoint's `Plug.Parsers`
  consumes the body once — a downstream plug that calls
  `Plug.Conn.read_body/2` for HMAC verification then gets `""` and
  every signature check fails.

  Webhook paths matched here bypass parsing entirely; the downstream
  plug is responsible for its own body reading and content-type
  handling.
  """

  @behaviour Plug

  @webhook_prefix ["internal", "webhooks"]

  @impl Plug
  def init(_opts) do
    Plug.Parsers.init(
      parsers: [:urlencoded, :json],
      pass: ["text/plain"],
      json_decoder: Phoenix.json_library(),
      length: 1_000_000
    )
  end

  @impl Plug
  def call(%Plug.Conn{path_info: @webhook_prefix ++ _rest} = conn, _opts), do: conn
  def call(conn, opts), do: Plug.Parsers.call(conn, opts)
end
