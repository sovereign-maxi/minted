defmodule Minted.Oracle.Client do
  @moduledoc """
  Finch-based HTTP client adapter for the oracle package sources.

  Implements the HTTPoison-compatible `get/3` interface that
  `Oracle.Sources.Coinbase`, `Binance`, and `Kraken` expect via
  `Application.get_env(:oracle, :http_client)`.
  """

  @doc """
  Performs an HTTP GET request.

  Returns `{:ok, %{status_code: integer(), body: binary()}}` on success
  or `{:error, %{reason: term()}}` on failure.
  """
  @spec get(String.t(), [{String.t(), String.t()}], keyword()) ::
          {:ok, %{status_code: integer(), body: binary()}} | {:error, %{reason: term()}}
  def get(url, headers, opts \\ []) do
    timeout = Keyword.get(opts, :recv_timeout, 10_000)

    request = Finch.build(:get, url, headers)

    case Finch.request(request, Minted.Finch, receive_timeout: timeout) do
      {:ok, %Finch.Response{status: status, body: body}} ->
        {:ok, %{status_code: status, body: body}}

      {:error, reason} ->
        {:error, %{reason: reason}}
    end
  end
end
