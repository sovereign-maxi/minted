defmodule Minted.ConnCase do
  @moduledoc """
  Test case for tests that need a connection to MintedWeb.Endpoint —
  e.g. LiveView state-machine tests.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      use MintedWeb, :verified_routes

      import Plug.Conn
      import Phoenix.ConnTest
      import Phoenix.LiveViewTest

      @endpoint MintedWeb.Endpoint
    end
  end

  setup _tags do
    # Pre-mark "welcomed" so the first-visit welcome modal doesn't
    # occlude LiveView assertions. Semantically correct — tests that
    # exercise application flows are past the "is this really the
    # right onion?" orientation step. Tests that specifically want
    # to exercise the welcome-modal path should build their own
    # conn without this session.
    conn =
      Phoenix.ConnTest.build_conn()
      |> Plug.Test.init_test_session(%{"welcomed" => true})

    {:ok, conn: conn}
  end
end
