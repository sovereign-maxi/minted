defmodule Minted.Lightning.Adapters.Client do
  @moduledoc """
  Reads Lightning config and builds the `{module, config}` tuple
  that `FireBird.Supervisor` expects.

  In production returns `{FireBird.HTTP, %FireBird.HTTP{...}}`.
  In test returns `{PhoenixdMock, %{}}`.
  """

  @doc """
  Returns a `{module, config}` tuple for FireBird.

  The module is the configured `:phoenixd_module` (default
  `Minted.Lightning.Adapters.Breakered`, which wraps `FireBird.HTTP`
  and routes `pay_invoice/5` through the circuit breaker).
  """
  @spec client_tuple() :: {module(), term()}
  def client_tuple do
    alias Minted.Lightning.Adapters.Breakered

    mod = Application.get_env(:minted, :phoenixd_module, Breakered)

    if mod == Breakered do
      config = lightning_config()

      http_config =
        FireBird.HTTP.new(
          base_url: Keyword.get(config, :phoenixd_url, "http://127.0.0.1:9740"),
          password: Keyword.fetch!(config, :phoenixd_password),
          finch_name: Minted.Finch,
          receive_timeout: Keyword.get(config, :phoenixd_timeout_ms, 30_000)
        )

      {Breakered, http_config}
    else
      # Test mock — no config needed.
      {mod, %{}}
    end
  end

  defp lightning_config do
    Application.get_env(:minted, :lightning, [])
  end
end
