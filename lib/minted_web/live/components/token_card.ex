defmodule MintedWeb.Live.Components.TokenCard do
  @moduledoc """
  Token card LiveComponent.

  Renders a horizontal bar chart showing token counts per denomination.
  Denominations are powers of 2 from 2^0 (1 sat) to 2^20 (1,048,576 sats),
  matching the Cashu denomination scheme.

  Bar widths use a logarithmic scale: `log2(count + 1) / log2(max_count + 1)`
  so that large token counts don't completely dominate the visual.

  Empty denominations are rendered but visually muted.
  """

  use MintedWeb, :live_component

  @denominations Enum.map(0..20, &Integer.pow(2, &1))

  # --- Lifecycle ---

  @impl true
  def update(%{_action: :refresh}, socket) do
    {:ok, socket}
  end

  def update(assigns, socket) do
    tokens = Map.get(assigns, :tokens, socket.assigns[:tokens] || [])

    {:ok,
     socket
     |> assign(assigns)
     |> compute_inventory(tokens)}
  end

  defp compute_inventory(socket, tokens) do
    counts = count_by_denomination(tokens)
    max_count = counts |> Map.values() |> Enum.max(fn -> 0 end)
    total = length(tokens)

    assign(socket,
      tokens: tokens,
      counts: counts,
      max_count: max_count,
      total: total,
      denominations: @denominations
    )
  end

  # --- Render ---

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mt-token-list">
      <%= if @total == 0 do %>
        <div class="bp-empty-state">No tokens yet</div>
      <% else %>
        <%= for {denom, count} <- active_denominations(@denominations, @counts) do %>
          <div class="mt-token-row">
            <span class="mt-token-denom">{format_denomination(denom)}</span>
            <div class="mt-token-bar-wrap">
              <div class="mt-token-bar" style={"width: #{bar_pct(count, @max_count)}%"}></div>
            </div>
            <span class="mt-token-count">x{count}</span>
          </div>
        <% end %>
      <% end %>
    </div>
    """
  end

  # --- Helpers ---

  defp count_by_denomination(tokens) when is_list(tokens) do
    tokens
    |> Enum.group_by(fn token -> Map.get(token, :amount, 0) end)
    |> Enum.into(%{}, fn {denom, group} -> {denom, length(group)} end)
  end

  defp count_by_denomination(_), do: %{}

  defp active_denominations(denominations, counts) do
    denominations
    |> Enum.map(fn denom -> {denom, Map.get(counts, denom, 0)} end)
    |> Enum.filter(fn {_denom, count} -> count > 0 end)
  end

  defp bar_pct(_count, max_count) when max_count <= 0, do: 0

  defp bar_pct(count, max_count) do
    round(count / max_count * 100)
  end

  defp format_denomination(amount) do
    amount
    |> Integer.to_string()
    |> String.graphemes()
    |> Enum.reverse()
    |> Enum.chunk_every(3)
    |> Enum.map(&Enum.reverse/1)
    |> Enum.reverse()
    |> Enum.map_join(",", &Enum.join/1)
  end
end
