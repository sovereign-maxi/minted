defmodule MintedWeb.InfoControllerTest do
  @moduledoc "Unit tests for MintedWeb.InfoController."

  use ExUnit.Case, async: false

  import Phoenix.ConnTest

  alias Minted.Mint.Keyset
  alias Minted.Storage.Keysets.Store

  @endpoint MintedWeb.Endpoint

  describe "GET /v1/info" do
    test "returns mint metadata" do
      conn = build_conn() |> get("/v1/info")

      body = json_response(conn, 200)
      assert body["name"] == "Minted"
      assert body["version"] == "Minted/0.1.0"
      assert is_map(body["nuts"])
      assert is_list(body["contact"])
    end

    test "includes supported NUTs" do
      conn = build_conn() |> get("/v1/info")

      nuts = json_response(conn, 200)["nuts"]
      assert nuts["4"]["disabled"] == false
      assert nuts["5"]["disabled"] == false
      assert nuts["7"]["supported"] == true
    end
  end

  describe "GET /v1/keysets" do
    test "returns keyset list" do
      conn = build_conn() |> get("/v1/keysets")

      body = json_response(conn, 200)
      assert is_list(body["keysets"])
    end

    test "keyset entries have expected shape" do
      # Seed a keyset so we can verify structure.
      keyset = Keyset.generate(unit: "sat")
      Store.put(keyset)

      conn = build_conn() |> get("/v1/keysets")

      body = json_response(conn, 200)
      assert [_ | _] = body["keysets"]

      entry = Enum.find(body["keysets"], &(&1["id"] == keyset.id))
      assert entry
      assert entry["unit"] == "sat"
      assert is_boolean(entry["active"])
    end
  end

  describe "GET /v1/keysets/:id" do
    test "returns keyset keys by ID" do
      keyset = Keyset.generate(unit: "sat")
      Store.put(keyset)

      conn = build_conn() |> get("/v1/keysets/#{keyset.id}")

      body = json_response(conn, 200)
      assert [ks] = body["keysets"]
      assert ks["id"] == keyset.id
      assert ks["unit"] == "sat"
      assert is_map(ks["keys"])
      assert map_size(ks["keys"]) == 21
    end

    test "returns 404 for unknown keyset" do
      conn = build_conn() |> get("/v1/keysets/nonexistent")

      body = json_response(conn, 404)
      assert body["detail"] == "Keyset not found"
      assert body["code"] == 10_011
    end
  end
end
