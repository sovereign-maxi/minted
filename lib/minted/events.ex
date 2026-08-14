defmodule Minted.Events do
  @moduledoc """
  Typed event definitions and EventBus for cross-context communication.

  All events are plain structs with `@enforce_keys` and `@type t`.
  Published/subscribed by module atom, not string topics.

  ## Topic Derivation

      Minted.Events.Mint.TokensMinted → "events:mint:tokens_minted"
      Minted.Events.Lightning.InvoicePaid → "events:lightning:invoice_paid"
  """

  defmodule EventBus do
    @moduledoc """
    Typed EventBus replacing `Minted.EventBus`.

    Publishes and subscribes using struct modules instead of string topics.
    Messages arrive as bare structs in `handle_info/2` — no `{:event, topic, payload}` wrapper.
    """

    @pubsub Minted.PubSub

    @spec publish(struct()) :: :ok
    def publish(%{__struct__: _} = event) do
      topic = topic_for_event(event)
      Phoenix.PubSub.local_broadcast(@pubsub, topic, event)
    end

    @spec publish(struct(), String.t()) :: :ok
    def publish(%{__struct__: _} = event, topic_suffix) do
      base = topic_for_event(event)
      Phoenix.PubSub.local_broadcast(@pubsub, "#{base}:#{topic_suffix}", event)
    end

    @spec subscribe(module()) :: :ok | {:error, term()}
    def subscribe(event_module) when is_atom(event_module) do
      Phoenix.PubSub.subscribe(@pubsub, topic_for_module(event_module))
    end

    @spec subscribe(module(), String.t()) :: :ok | {:error, term()}
    def subscribe(event_module, topic_suffix) when is_atom(event_module) do
      base = topic_for_module(event_module)
      Phoenix.PubSub.subscribe(@pubsub, "#{base}:#{topic_suffix}")
    end

    @spec unsubscribe(module()) :: :ok
    def unsubscribe(event_module) when is_atom(event_module) do
      Phoenix.PubSub.unsubscribe(@pubsub, topic_for_module(event_module))
    end

    @spec unsubscribe(module(), String.t()) :: :ok
    def unsubscribe(event_module, topic_suffix) when is_atom(event_module) do
      base = topic_for_module(event_module)
      Phoenix.PubSub.unsubscribe(@pubsub, "#{base}:#{topic_suffix}")
    end

    @doc false
    def topic_for_module(module) do
      module
      |> Module.split()
      |> Enum.drop(2)
      |> Enum.map_join(":", &Macro.underscore/1)
      |> then(&"events:#{&1}")
    end

    defp topic_for_event(%{__struct__: module}), do: topic_for_module(module)
  end
end
