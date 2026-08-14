defmodule MintedWeb.Live.Components.ActivityFeed do
  @moduledoc """
  Activity feed LiveComponent showing recent wallet operations.

  Renders a scrollable list of deposit and withdrawal entries with relative
  timestamps and status-colored indicators.

  WAL-backed — persists across reloads. Maximum 50 entries, newest first.

  ## Required assigns

    * `:activities` — list of maps with `:type`, `:amount`, `:status`, `:at`
  """

  use MintedWeb, :live_component

  import Minted.Format, only: [format_sats: 1]

  @max_entries 50
  @tick_interval_ms 60_000

  @type_labels %{
    deposit: "Deposit",
    withdrawal: "Withdraw",
    receive: "Restore"
  }

  # --- Lifecycle ---

  @impl true
  def update(%{_action: :tick}, socket) do
    schedule_tick(socket.assigns.id)
    now = DateTime.utc_now()

    activities =
      Enum.map(socket.assigns.activities, fn activity ->
        if activity[:new] && DateTime.diff(now, activity.at, :second) > 30 do
          Map.put(activity, :new, false)
        else
          activity
        end
      end)

    {:ok, socket |> assign(:activities, activities) |> assign(:now, now)}
  end

  def update(assigns, socket) do
    activities =
      assigns
      |> Map.get(:activities, [])
      |> Enum.take(@max_entries)

    if not Map.has_key?(socket.assigns, :tick_scheduled) do
      schedule_tick(assigns.id)
    end

    {:ok,
     socket
     |> assign(:id, assigns.id)
     |> assign(:activities, activities)
     |> assign(:now, DateTime.utc_now())
     |> assign(:tick_scheduled, true)}
  end

  # --- Render ---

  @impl true
  def render(assigns) do
    ~H"""
    <div id={@id}>
      <div :if={@activities == []} class="bp-empty-state">No activity yet</div>
      <ol :if={@activities != []} class="mt-activity-feed" role="log" aria-label="Activity feed">
        <li
          :for={activity <- @activities}
          class={"mt-activity-row#{if activity[:new], do: " new", else: ""}"}
        >
          <span class={"mt-activity-icon #{icon_class(activity.type)}"}>
            {type_label_upper(activity.type)}
          </span>
          <span class="mt-activity-detail">
            {amount_prefix(activity.type)}{format_sats(activity.amount)} sats
            <span class="mt-activity-dim">{detail_verb(activity.type)}</span>
          </span>
          <span class="mt-activity-time">{relative_time(activity.at, @now)}</span>
        </li>
      </ol>
    </div>
    """
  end

  # --- Helpers ---

  @doc """
  Converts a `DateTime` to a human-readable relative time string.

  Examples: "just now", "2m ago", "1h ago", "3d ago".
  """
  @spec relative_time(DateTime.t(), DateTime.t()) :: String.t()
  def relative_time(%DateTime{} = dt, %DateTime{} = now) do
    diff_seconds = DateTime.diff(now, dt, :second)

    cond do
      diff_seconds < 5 -> "just now"
      diff_seconds < 60 -> "#{diff_seconds}s ago"
      diff_seconds < 3_600 -> "#{div(diff_seconds, 60)}m ago"
      diff_seconds < 86_400 -> "#{div(diff_seconds, 3_600)}h ago"
      diff_seconds < 604_800 -> "#{div(diff_seconds, 86_400)}d ago"
      true -> Calendar.strftime(dt, "%Y-%m-%d")
    end
  end

  def relative_time(_, _), do: "--"

  defp type_label_upper(type), do: Map.get(@type_labels, type, to_string(type)) |> String.upcase()

  @icon_classes %{
    deposit: "ok",
    withdrawal: "ok",
    receive: "ok"
  }

  defp icon_class(type), do: Map.get(@icon_classes, type, to_string(type))

  @detail_verbs %{
    deposit: "Tokens minted",
    withdrawal: "Tokens melted",
    receive: "Tokens restored"
  }

  defp detail_verb(type), do: Map.get(@detail_verbs, type, "")

  defp amount_prefix(:deposit), do: "+"
  defp amount_prefix(:receive), do: "+"
  defp amount_prefix(:withdrawal), do: "-"
  defp amount_prefix(_), do: ""

  defp schedule_tick(id) do
    send_update_after(__MODULE__, [id: id, _action: :tick], @tick_interval_ms)
  end
end
