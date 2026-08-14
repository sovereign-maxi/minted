defmodule MintedWeb.Plugs.PhoenixdWebhook do
  @moduledoc """
  Thin wrapper around `FireBird.Webhook` that reads the shared HMAC
  secret from application config at request time. `Plug.Router`
  compiles `forward` opts at compile time, so a plain `forward` cannot
  see runtime config (secret is bound in `config/runtime.exs`).
  """

  @behaviour Plug

  @impl Plug
  def init(_opts), do: []

  @impl Plug
  def call(conn, _opts) do
    FireBird.Webhook.call(conn, firebird_opts())
  end

  defp firebird_opts do
    case :persistent_term.get({__MODULE__, :opts}, :undefined) do
      :undefined ->
        opts =
          FireBird.Webhook.init(
            webhook_secret: Application.fetch_env!(:minted, :webhook_secret),
            invoice_manager: FireBird.Manager,
            dedup_table: FireBird.Webhook,
            rate_limit_table: FireBird.Webhook.RateLimit
          )

        :persistent_term.put({__MODULE__, :opts}, opts)
        opts

      opts ->
        opts
    end
  end
end
