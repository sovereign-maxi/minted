defmodule Minted.Telemetry.Formatter do
  @moduledoc false

  require Logger

  @sensitive_keys MapSet.new([
                    :secret,
                    :C,
                    :C_,
                    :r,
                    :blinding_factor,
                    :preimage,
                    :payment_secret,
                    :private_key,
                    :secret_key,
                    :sk,
                    :key_share,
                    :nonce,
                    :b_prime,
                    :c_prime,
                    :password,
                    :webhook_secret,
                    :bearer_token,
                    :token,
                    :hmac
                  ])

  @compiled_pattern Logger.Formatter.compile("$time $metadata[$level] $message\n")

  @doc "Formats a log message, redacting sensitive metadata."
  @spec format(Logger.level(), Logger.message(), term(), keyword()) :: IO.chardata()
  def format(level, message, timestamp, metadata) do
    safe_metadata = redact_metadata(metadata)
    safe_message = redact_string(IO.chardata_to_string(message))

    Logger.Formatter.format(
      @compiled_pattern,
      level,
      safe_message,
      timestamp,
      safe_metadata
    )
  rescue
    e ->
      Logger.warning("Formatter: format failed: #{inspect(e)}")
      "#{inspect(timestamp)} [#{level}] FORMAT_ERROR\n"
  end

  @doc "Redacts sensitive keys from a keyword list of metadata."
  @spec redact_metadata(keyword()) :: keyword()
  def redact_metadata(metadata) do
    Enum.map(metadata, fn {key, value} ->
      if MapSet.member?(@sensitive_keys, key) do
        {key, "[REDACTED]"}
      else
        {key, redact_value(value)}
      end
    end)
  end

  @doc "Returns the set of sensitive key names."
  @spec sensitive_keys() :: MapSet.t()
  def sensitive_keys, do: @sensitive_keys

  # --- Private ---

  defp redact_value(value) when is_map(value) do
    Map.new(value, fn {k, v} ->
      if is_atom(k) and MapSet.member?(@sensitive_keys, k) do
        {k, "[REDACTED]"}
      else
        {k, redact_value(v)}
      end
    end)
  end

  defp redact_value(value), do: value

  defp redact_string(message) do
    Enum.reduce(sensitive_patterns(), message, fn pattern, msg ->
      String.replace(msg, pattern, "[REDACTED]")
    end)
  end

  defp sensitive_patterns do
    [
      ~r/secret=\S+/,
      ~r/preimage=\S+/,
      ~r/private_key=\S+/,
      ~r/blinding_factor=\S+/
    ]
  end
end
