# Unit test
defmodule Minted.Mint.Keysets.LoaderTest do
  @moduledoc "Unit tests for Minted.Mint.Keysets.Loader."

  use ExUnit.Case, async: true

  alias Minted.Mint.Keysets.Loader

  defp write_keyset_json(denom_keys) do
    path =
      Path.join(System.tmp_dir!(), "minted_loader_test_#{:erlang.unique_integer([:positive])}.json")

    File.write!(path, Jason.encode!(%{"denomination_keys" => denom_keys}))
    on_exit(fn -> File.rm(path) end)
    path
  end

  test "rejects a pubkey that does not derive from its privkey" do
    {:ok, {priv_a, _pub_a}} = Cashew.generate_keypair()
    {:ok, {_priv_b, pub_b}} = Cashew.generate_keypair()

    path =
      write_keyset_json(%{
        "1" => %{
          "private_key" => Base.encode16(priv_a, case: :lower),
          "public_key" => Base.encode16(pub_b, case: :lower)
        }
      })

    assert {:error, {:pubkey_mismatch, 1}} = Loader.load_and_install(path)
  end

  test "rejects malformed key hex" do
    path = write_keyset_json(%{"1" => %{"private_key" => "zz", "public_key" => "zz"}})
    assert {:error, {:parse_failed, _}} = Loader.load_and_install(path)
  end
end
