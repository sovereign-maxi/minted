defmodule Minted.Telemetry.Filter do
  @moduledoc """
  Logger metadata filter that strips sensitive fields before they reach
  the formatter. Attach to Logger as a primary filter.
  """

  alias Minted.Telemetry.Formatter

  @doc """
  Filter function for Logger. Redacts sensitive metadata keys.

  Usage in config:
      config :logger, :default_handler,
        filters: [safe_metadata: {&Filter.filter/2, []}]
  """
  @spec filter(:logger.log_event(), term()) :: :logger.log_event() | :stop
  def filter(%{meta: meta} = event, _extra) do
    safe_meta =
      Map.new(meta, fn {k, v} ->
        if is_atom(k) and MapSet.member?(Formatter.sensitive_keys(), k) do
          {k, "[REDACTED]"}
        else
          {k, v}
        end
      end)

    %{event | meta: safe_meta}
  end

  def filter(event, _extra), do: event
end
