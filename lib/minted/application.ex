defmodule Minted.Application do
  @moduledoc false

  use Application

  alias Minted.Mint.Keyset
  alias Minted.Mint.Keysets.Loader
  alias Minted.Storage.Facade, as: StorageFacade

  require Logger

  @impl true
  def start(_type, _args) do
    # Verify NIF is loaded before starting any services that depend on it.
    Cashew.ensure_loaded!()

    # Record start time for uptime calculation (admin dashboard)
    :persistent_term.put(:app_started_at, System.monotonic_time(:millisecond))

    # Create directory tree before any supervisor starts.
    StorageFacade.ensure_dirs!()

    # Startup checks: data dir writability (Issue 2/7).
    startup_checks!()

    # Restore halt state from the operator audit log before any
    # supervisor starts accepting traffic. If the operator halted
    # the mint during an incident and then `systemctl restart`'d
    # for any reason, this re-establishes the persistent_term flag
    # so token issuance stays disabled until the operator
    # explicitly clears it.
    _ = Minted.Operator.Audit.replay_halt_state()

    # Supervisor strategy is :rest_for_one — children stop in REVERSE order.
    # This ensures Lightning (Executor) can still write to WAL during
    # its terminate/2, because Storage.Supervisor stops after Lightning.
    children = [
      {Phoenix.PubSub, name: Minted.PubSub},
      {Task.Supervisor, name: Minted.TaskSupervisor},
      {Finch, name: Minted.Finch, pools: finch_pools()},
      Minted.Storage.Supervisor,
      Minted.Mint.Supervisor,
      Minted.Lightning.Supervisor,
      # Bootstrap trigger — runs ONCE after the supervision tree is up.
      # Loads keyset from JSON or generates a fresh one if no active
      # keyset exists (fresh install). On normal restarts this is a no-op.
      %{
        id: :keyset_bootstrap,
        start: {Task, :start_link, [&maybe_bootstrap/0]},
        restart: :temporary
      },
      Minted.Identity.Supervisor,
      Minted.Reserves.Supervisor,
      Minted.Telemetry.Supervisor,
      Minted.Oracle.Supervisor,
      MintedWeb.Endpoint,
      MintedAdminWeb.Endpoint
    ]

    # Explicit restart budget for financial application:
    # 5 restarts in 30 seconds before supervisor gives up.
    opts = [strategy: :rest_for_one, name: Minted.Supervisor, max_restarts: 5, max_seconds: 30]
    Supervisor.start_link(children, opts)
  end

  # --- Keyset bootstrap ---
  #
  # On fresh install (no active keyset in Store), loads a keyset from
  # a JSON file deployed by Ansible. If no JSON exists, generates a
  # fresh keyset with full private keys.

  defp maybe_bootstrap do
    keyset_path = keyset_config_path()

    case StorageFacade.get_active_keyset() do
      [_ | _] ->
        Logger.info("Application: active keyset found, skipping bootstrap")
        # A leftover keyset.json means a previous bootstrap crashed
        # between install and delete — finish the job rather than
        # leave plaintext private keys on disk indefinitely.
        delete_stale_bootstrap_keyset(keyset_path)

      [] ->
        bootstrap_fresh(keyset_path)
    end
  rescue
    e ->
      Logger.error("Application: bootstrap check failed: #{Exception.message(e)}")
      halt_on_bootstrap_failure(Exception.message(e))
  catch
    :exit, reason ->
      Logger.error("Application: bootstrap check crashed: #{inspect(reason)}")
      halt_on_bootstrap_failure("bootstrap exit: #{inspect(reason)}")
  end

  defp bootstrap_fresh(keyset_path) do
    if File.exists?(keyset_path) do
      Logger.info("Application: no active keyset — loading from #{keyset_path}")

      case Loader.load_and_install(keyset_path) do
        {:ok, keyset_id} ->
          Logger.info("Application: keyset #{keyset_id} installed from config")
          # The bootstrap JSON holds PLAINTEXT private keys — it
          # exists only as a hand-off from installer to the
          # encrypted Store. Leaving it on disk means the runbook's
          # `expire_keyset` kill switch is a lie, backups carry
          # unwrapped material, and any operator-account
          # compromise exposes it. Best-effort remove after
          # install; a stray file in the keys dir is a loud
          # enough breadcrumb that the operator will notice.
          delete_bootstrap_keyset(keyset_path)

        {:error, reason} ->
          Logger.error("Application: key loading failed: #{inspect(reason)}")
          halt_on_bootstrap_failure("keyset load failed: #{inspect(reason)}")
      end
    else
      Logger.info("Application: no active keyset and no JSON — generating fresh keyset")
      keyset = Keyset.generate()

      case StorageFacade.put_keyset(Keyset.to_store_map(keyset)) do
        :ok ->
          Logger.info("Application: generated keyset #{keyset.id}")

        {:error, reason} ->
          halt_on_bootstrap_failure("keyset install failed: #{inspect(reason)}")
      end
    end
  end

  defp delete_stale_bootstrap_keyset(path) do
    if File.exists?(path) do
      Logger.warning(
        "Application: bootstrap keyset JSON present alongside an active keyset — " <>
          "a previous bootstrap crashed before deleting it; removing now"
      )

      delete_bootstrap_keyset(path)
    end
  end

  # A mint without a keyset can't sign — fail closed instead of
  # serving keyset_not_found forever. The halt persists across
  # restarts (state file + audit log) until the operator fixes the
  # bootstrap input and clears it.
  defp halt_on_bootstrap_failure(message) do
    Logger.error("Application: keyset bootstrap failed, halting: #{message}")
    Minted.Telemetry.Facade.set_halted("keyset bootstrap failed: #{message}")
  end

  defp keyset_config_path do
    Path.join(StorageFacade.keys_path(), "keyset.json")
  end

  defp delete_bootstrap_keyset(path) do
    case File.rm(path) do
      :ok ->
        Logger.info("Application: bootstrap keyset JSON deleted, path=#{path}")

      {:error, reason} ->
        Logger.error(
          "Application: failed to delete bootstrap keyset JSON, " <>
            "plaintext private keys remain on disk, path=#{path}, reason=#{inspect(reason)}"
        )
    end
  end

  # --- Startup checks ---

  defp startup_checks! do
    check_data_dir!()
  end

  # Finch is the sole outbound HTTP client (Nostr relay publishing,
  # price feeds, and Phoenixd API). In production, external traffic
  # routes through the Tor HTTP CONNECT tunnel so the mint's server
  # IP is never visible. Phoenixd is on loopback and MUST NOT go
  # through the tunnel — the Tor exit node's 127.0.0.1 is not our
  # 127.0.0.1. A separate pool for the Phoenixd URL bypasses the
  # proxy while all other requests use the default (proxied) pool.
  #
  # Fail-closed: if :env is :prod and no tor tunnel is configured,
  # boot refuses to proceed.
  defp finch_pools do
    env = Application.get_env(:minted, :env, :dev)
    tunnel = Application.get_env(:minted, :tor_http_tunnel)
    phoenixd_url = Application.get_env(:minted, :lightning, []) |> Keyword.get(:phoenixd_url, "http://127.0.0.1:9740")

    base_opts = [
      transport_opts: [
        verify: :verify_peer,
        cacerts: :public_key.cacerts_get(),
        depth: 3
      ]
    ]

    case {env, tunnel} do
      {:prod, nil} ->
        raise "Minted: production boot refuses clearnet egress. " <>
                "Set TOR_HTTP_TUNNEL_PORT (and optionally TOR_HTTP_TUNNEL_HOST) " <>
                "to route all outbound HTTP through Tor."

      {_, nil} ->
        %{:default => [conn_opts: base_opts]}

      {_, {host, port}} when is_binary(host) and is_integer(port) ->
        Logger.info("Application: Finch routing through Tor HTTP tunnel #{host}:#{port}")

        pools = %{
          :default => [conn_opts: [proxy: {:http, host, port, []}] ++ base_opts]
        }

        # Only add a direct (non-proxied) pool for Phoenixd if it's on localhost.
        # Remote Phoenixd (.onion) should go through the Tor proxy like everything else.
        if String.contains?(phoenixd_url, "127.0.0.1") or String.contains?(phoenixd_url, "localhost") do
          Map.put(pools, phoenixd_url, conn_opts: base_opts)
        else
          pools
        end
    end
  end

  # Verify the data directory is writable and restrict its permissions.
  # Raises in prod if the directory cannot be written; warns in dev.
  defp check_data_dir! do
    data_dir = StorageFacade.base_dir()
    env = Application.get_env(:minted, :env, :dev)

    File.mkdir_p!(data_dir)

    probe_path = Path.join(data_dir, ".startup_probe")

    result =
      with :ok <- File.write(probe_path, "ok"),
           {:ok, "ok"} <- File.read(probe_path),
           :ok <- File.rm(probe_path) do
        File.chmod(data_dir, 0o700)
      end

    case result do
      :ok ->
        :ok

      {:error, reason} when env == :prod ->
        raise "Data directory #{data_dir} is not writable or could not be secured: #{reason}"

      {:error, reason} ->
        Logger.warning("Application: data directory probe failed (#{reason}) — acceptable in dev/test")
    end
  end
end
