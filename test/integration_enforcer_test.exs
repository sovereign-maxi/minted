defmodule Minted.IntegrationEnforcerTest do
  @moduledoc """
  Regression guard: every file under `test/integration/` MUST use
  one of the IntegrationCase templates. Bypassing them (via bare
  `use ExUnit.Case`) skips `Minted.TestHelpers.StateHelpers.clean_state/1`,
  which resets the per-test ETS state (mint pending / spent set,
  lightning invoice + payment tables, reserves liability counter,
  halt state). Without that reset, tests leak state into each other
  and flake under specific test seeds.

  See `test/support/state_helpers.ex` for the full reset surface.
  """

  use ExUnit.Case, async: true

  @integration_root "test/integration"
  @allowed_templates [
    "use Minted.IntegrationCase",
    "use MintedWeb.IntegrationCase"
  ]

  test "every integration test file uses an IntegrationCase template" do
    violations =
      Path.wildcard(Path.join([@integration_root, "**", "*_test.exs"]))
      |> Enum.filter(fn path ->
        content = File.read!(path)
        not Enum.any?(@allowed_templates, &String.contains?(content, &1))
      end)
      |> Enum.sort()

    assert violations == [], """
    Integration test files must `use` one of these case templates:

    #{Enum.join(@allowed_templates, "\n")}

    Bypassing them means `clean_state/1` doesn't run and cross-test
    state leaks (mint pending / spent set, lightning invoice + payment
    tables, reserves liability counter, halt state).

    Violating files:
    #{Enum.map_join(violations, "\n", &"  #{&1}")}
    """
  end
end
