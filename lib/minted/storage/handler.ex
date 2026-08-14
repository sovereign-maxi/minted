defmodule Minted.Storage.Handler do
  @moduledoc false

  use GenServer

  require Logger

  alias Minted.Events.EventBus
  alias Minted.Events.Storage

  @event_modules [
    Storage.KeysetCreated,
    Storage.KeysetExpired,
    Storage.CompactionCompleted,
    Storage.RecoveryCompleted
  ]

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(_opts) do
    Enum.each(@event_modules, &EventBus.subscribe/1)
    {:ok, %{event_count: 0}}
  end

  @impl true
  def handle_info(%{__struct__: module} = event, state) do
    Logger.debug("Handler: storage event [#{inspect(module)}]: #{inspect(event)}")
    {:noreply, %{state | event_count: state.event_count + 1}}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end
end
