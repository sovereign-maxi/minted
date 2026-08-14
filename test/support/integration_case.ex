defmodule Minted.IntegrationCase do
  @moduledoc """
  Shared test setup for non-web integration tests.

  Runs `Minted.TestHelpers.StateHelpers.clean_state/1` before every
  test so per-test state doesn't leak across files under the shared
  BEAM. Use this for anything under `test/integration/` that isn't
  driving `MintedWeb` LiveViews / controllers.

      use Minted.IntegrationCase

      test "..." do
        # Mint / Lightning / Reserves / Storage ETS tables cleared,
        # halt state cleared. Add your own `setup` block for
        # per-test fixtures.
      end
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      use ExUnit.Case, async: false
      import Minted.TestHelpers.StateHelpers

      @moduletag :integration

      setup :clean_state
    end
  end
end

defmodule MintedWeb.IntegrationCase do
  @moduledoc """
  Shared test setup for MintedWeb LiveView + controller integration tests.

  Same isolation contract as `Minted.IntegrationCase` (runs
  `clean_state` per test) plus Phoenix wiring: `verified_routes`,
  `Plug.Conn` / `Phoenix.ConnTest` / `Phoenix.LiveViewTest` imports,
  `@endpoint MintedWeb.Endpoint`, and a fresh `conn:` context with
  `"welcomed" => true` pre-marked so the first-visit modal doesn't
  occlude LiveView assertions.

  Tests that specifically want to exercise the welcome-modal path
  should build their own conn without this session — see
  `MintedWeb.WelcomeControllerTest`.

      use MintedWeb.IntegrationCase

      test "returns 200", %{conn: conn} do
        conn = get(conn, ~p"/wallet")
        assert html_response(conn, 200)
      end
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      use ExUnit.Case, async: false
      use MintedWeb, :verified_routes

      import Plug.Conn
      import Phoenix.ConnTest
      import Phoenix.LiveViewTest
      import Minted.TestHelpers.StateHelpers

      @endpoint MintedWeb.Endpoint

      @moduletag :integration

      setup :clean_state

      setup do
        conn =
          Phoenix.ConnTest.build_conn()
          |> Plug.Test.init_test_session(%{"welcomed" => true})

        {:ok, conn: conn}
      end
    end
  end
end
