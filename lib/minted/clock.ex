defmodule Minted.Clock do
  @moduledoc """
  Behaviour + dispatch for time operations.

  Delegates to `Minted.Clock.System` by default; in tests, configure
  `:minted, :clock` to a Mox mock for deterministic, instant assertions.
  """

  @callback utc_now() :: DateTime.t()
  @callback monotonic_time() :: integer()
  @callback send_after(pid(), term(), non_neg_integer()) :: reference()

  def utc_now, do: impl().utc_now()
  def monotonic_time, do: impl().monotonic_time()
  def send_after(pid, msg, ms), do: impl().send_after(pid, msg, ms)

  if Mix.env() == :test do
    defp impl, do: Application.get_env(:minted, :clock, Minted.Clock.System)
  else
    # Runtime-swappable only in tests. Every other environment pins the
    # system clock so a stray Application.put_env can never replace the
    # clock underneath payment-timeout scheduling.
    defp impl, do: Minted.Clock.System
  end
end

defmodule Minted.Clock.System do
  @moduledoc false
  @behaviour Minted.Clock

  @impl true
  def utc_now, do: DateTime.utc_now()

  @impl true
  def monotonic_time, do: System.monotonic_time()

  @impl true
  def send_after(pid, msg, ms), do: Process.send_after(pid, msg, ms)
end
