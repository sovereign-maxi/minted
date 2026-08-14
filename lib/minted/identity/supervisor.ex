defmodule Minted.Identity.Supervisor do
  @moduledoc false
  use Supervisor

  def start_link(init_arg) do
    Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @spec healthy?() :: boolean()
  def healthy? do
    __MODULE__
    |> Supervisor.which_children()
    |> Enum.all?(fn {_id, pid, _type, _modules} ->
      is_pid(pid) and Process.alive?(pid)
    end)
  end

  @impl true
  def init(_init_arg) do
    identity_cfg = Application.get_env(:minted, :identity, [])

    children = [
      Seer.NonceStore,
      {Seer.RateLimiter,
       [
         # Every operation classified by Minted.Identity.Gate.classify_operation/1
         # MUST have an entry here — unknown operations are silently accepted
         # as {:ok, conn} (see gate.ex:98-99), which previously let :check and
         # :expensive bypass rate limiting entirely.
         limits: %{
           deposit: {10, 300},
           withdraw: {5, 300},
           swap: {20, 300},
           info: {100, 60},
           check: {30, 60},
           expensive: {5, 60}
         },
         global_multiplier: 10
       ]},
      {Seer.Difficulty,
       [
         min_difficulty: Keyword.get(identity_cfg, :pow_min_difficulty, 12),
         max_difficulty: Keyword.get(identity_cfg, :pow_max_difficulty, 28)
       ]},
      {Seer.Escalation, []},
      {Minted.Identity.Escalation, []}
    ]

    Supervisor.init(children, strategy: :rest_for_one, max_restarts: 3, max_seconds: 10)
  end
end
