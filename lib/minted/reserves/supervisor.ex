defmodule Minted.Reserves.Supervisor do
  @moduledoc false

  use Supervisor

  def start_link(init_arg) do
    Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  alias Minted.Storage.Facade, as: StorageFacade

  @impl true
  def init(_init_arg) do
    proof_interval = get_config(:proof_interval_ms, 60 * 1_000)

    generator_opts = [
      source: Minted.Reserves.Source,
      publishers: [Minted.Reserves.Publishers.Event, Minted.Reserves.Publishers.Vault],
      interval_ms: proof_interval,
      dets_file: StorageFacade.reserves_proofs_path(),
      keys_dir: StorageFacade.keys_path(),
      cipher: {&StorageFacade.encrypt/1, &StorageFacade.decrypt/1},
      halt_check: fn -> if Minted.Guards.operational?(), do: :ok, else: :halted end
    ]

    generator_opts =
      case get_config(:signer, &Minted.Reserves.Signer.sign/2) do
        :default -> generator_opts
        signer -> Keyword.put(generator_opts, :signer, signer)
      end

    children = [
      # LiabilityCounter and FeeCounter live in Storage.Supervisor
      # so they're available during WAL recovery.

      # Thin wrappers that subscribe to events and delegate to Locker.Counter
      Minted.Reserves.Trackers.Liability,
      Minted.Reserves.Trackers.Fees,
      Minted.Reserves.Publishers.Nostr,
      {Vault.Generator, generator_opts}
    ]

    # Wider window than the supervisor default so a transient relay
    # outage that crashes the Nostr publisher a few times in quick
    # succession doesn't tear down the whole reserves subtree.
    Supervisor.init(children, strategy: :rest_for_one, max_restarts: 5, max_seconds: 60)
  end

  defp get_config(key, default) do
    Application.get_env(:minted, :reserves, [])
    |> Keyword.get(key, default)
  end
end
