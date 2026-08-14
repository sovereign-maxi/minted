defmodule Minted.Mint.TokenTest do
  @moduledoc "Unit tests for Minted.Mint.Token."

  use ExUnit.Case, async: true

  alias Minted.Mint.Token

  describe "valid_denomination?/1" do
    test "accepts all power-of-2 denominations" do
      for exp <- 0..20 do
        denom = Integer.pow(2, exp)
        assert Token.valid_denomination?(denom), "expected #{denom} to be valid"
      end
    end

    test "rejects non-power-of-2 values" do
      refute Token.valid_denomination?(3)
      refute Token.valid_denomination?(5)
      refute Token.valid_denomination?(6)
      refute Token.valid_denomination?(7)
      refute Token.valid_denomination?(100)
      refute Token.valid_denomination?(0)
      refute Token.valid_denomination?(-1)
    end
  end

  describe "decompose_amount/1" do
    test "zero returns empty list" do
      assert Token.decompose_amount(0) == []
    end

    test "powers of 2 return single element" do
      assert Token.decompose_amount(1) == [1]
      assert Token.decompose_amount(2) == [2]
      assert Token.decompose_amount(4) == [4]
      assert Token.decompose_amount(1024) == [1024]
    end

    test "composite amounts decompose correctly" do
      assert Token.decompose_amount(13) == [1, 4, 8]
      assert Token.decompose_amount(7) == [1, 2, 4]
      assert Token.decompose_amount(15) == [1, 2, 4, 8]
      assert Token.decompose_amount(100) == [4, 32, 64]
    end

    test "decomposition sums to original amount" do
      for amount <- [1, 7, 13, 42, 100, 255, 1000, 1_048_576] do
        parts = Token.decompose_amount(amount)
        assert Enum.sum(parts) == amount, "decompose(#{amount}) sums to #{Enum.sum(parts)}"
      end
    end

    test "decomposition produces ascending order" do
      parts = Token.decompose_amount(255)
      assert parts == Enum.sort(parts)
    end

    test "all parts are powers of 2" do
      parts = Token.decompose_amount(12_345)

      for part <- parts do
        assert Token.valid_denomination?(part), "expected #{part} to be a valid denomination"
      end
    end
  end

  describe "serialize/1 and deserialize/1" do
    test "roundtrip serialization" do
      tokens = [
        %Token{
          amount: 8,
          secret: :crypto.strong_rand_bytes(32),
          c: :crypto.strong_rand_bytes(33),
          keyset_id: "abcdef01"
        },
        %Token{
          amount: 4,
          secret: :crypto.strong_rand_bytes(32),
          c: :crypto.strong_rand_bytes(33),
          keyset_id: "abcdef01"
        }
      ]

      assert {:ok, serialized} = Token.serialize(tokens)
      assert String.starts_with?(serialized, "cashuA")

      {:ok, deserialized} = Token.deserialize(serialized)
      assert length(deserialized) == 2

      for {original, parsed} <- Enum.zip(tokens, deserialized) do
        assert original.amount == parsed.amount
        assert original.secret == parsed.secret
        assert original.c == parsed.c
        assert original.keyset_id == parsed.keyset_id
      end
    end

    test "invalid format returns error" do
      assert {:error, :invalid_format} = Token.deserialize("invalid")
    end

    test "invalid hex in secret field returns error" do
      payload = %{
        "token" => [
          %{"proofs" => [%{"amount" => 1, "secret" => "ZZZZ", "C" => "AA", "id" => "abc"}]}
        ]
      }

      encoded = "cashuA" <> Base.url_encode64(Jason.encode!(payload), padding: false)
      assert {:error, :invalid_proof_encoding} = Token.deserialize(encoded)
    end

    test "invalid hex in C field returns error" do
      payload = %{
        "token" => [
          %{"proofs" => [%{"amount" => 1, "secret" => "AA", "C" => "ZZZZ", "id" => "abc"}]}
        ]
      }

      encoded = "cashuA" <> Base.url_encode64(Jason.encode!(payload), padding: false)
      assert {:error, :invalid_proof_encoding} = Token.deserialize(encoded)
    end

    test "missing proofs key in token entry returns error" do
      payload = %{"token" => [%{"not_proofs" => []}]}
      encoded = "cashuA" <> Base.url_encode64(Jason.encode!(payload), padding: false)
      assert {:error, :invalid_proof_encoding} = Token.deserialize(encoded)
    end

    test "serialize returns {:ok, string} on success (#41)" do
      token = %Token{
        amount: 1,
        secret: :crypto.strong_rand_bytes(32),
        c: :crypto.strong_rand_bytes(33),
        keyset_id: "test01"
      }

      assert {:ok, serialized} = Token.serialize([token])
      assert is_binary(serialized)
      assert String.starts_with?(serialized, "cashuA")
    end

    test "serialize returns {:error, _} on non-serializable input (#41)" do
      # A token with a PID in keyset_id cannot be JSON-encoded.
      token = %Token{
        amount: 1,
        secret: :crypto.strong_rand_bytes(32),
        c: :crypto.strong_rand_bytes(33),
        keyset_id: self()
      }

      assert {:error, _} = Token.serialize([token])
    end
  end

  describe "deserialize/1 input limits" do
    test "rejects oversized backup string" do
      # Generate a string over 10 MB.
      huge = String.duplicate("A", 10_000_001)
      assert {:error, :backup_too_large} = Token.deserialize("cashuA" <> huge)
    end

    test "rejects non-cashuA prefix" do
      assert {:error, :invalid_format} = Token.deserialize("cashuB" <> "data")
      assert {:error, :invalid_format} = Token.deserialize("")
      assert {:error, :invalid_format} = Token.deserialize("random_string")
    end

    test "rejects non-list token entries" do
      payload = %{"token" => "not_a_list"}
      encoded = "cashuA" <> Base.url_encode64(Jason.encode!(payload), padding: false)
      assert {:error, :invalid_format} = Token.deserialize(encoded)
    end

    test "rejects oversized keyset_id" do
      long_id = String.duplicate("x", 65)

      payload = %{
        "token" => [
          %{
            "proofs" => [
              %{
                "amount" => 1,
                "secret" => Base.encode16(:crypto.strong_rand_bytes(32), case: :lower),
                "C" => Base.encode16(:crypto.strong_rand_bytes(33), case: :lower),
                "id" => long_id
              }
            ]
          }
        ]
      }

      encoded = "cashuA" <> Base.url_encode64(Jason.encode!(payload), padding: false)
      assert {:error, :invalid_proof_encoding} = Token.deserialize(encoded)
    end

    test "accepts keyset_id at max length (16 hex chars)" do
      id_64 = String.duplicate("a", 16)

      payload = %{
        "token" => [
          %{
            "proofs" => [
              %{
                "amount" => 1,
                "secret" => Base.encode16(:crypto.strong_rand_bytes(32), case: :lower),
                "C" => Base.encode16(:crypto.strong_rand_bytes(33), case: :lower),
                "id" => id_64
              }
            ]
          }
        ]
      }

      encoded = "cashuA" <> Base.url_encode64(Jason.encode!(payload), padding: false)
      assert {:ok, [token]} = Token.deserialize(encoded)
      assert token.keyset_id == id_64
    end

    test "rejects invalid base64 after cashuA prefix" do
      assert {:error, :invalid_encoding} = Token.deserialize("cashuA!!!not-base64!!!")
    end

    test "rejects missing token key in JSON" do
      payload = %{"not_token" => []}
      encoded = "cashuA" <> Base.url_encode64(Jason.encode!(payload), padding: false)
      assert {:error, :invalid_format} = Token.deserialize(encoded)
    end

    test "rejects non-power-of-2 amount" do
      payload = %{
        "token" => [
          %{
            "proofs" => [
              %{
                "amount" => 3,
                "secret" => Base.encode16(:crypto.strong_rand_bytes(32), case: :lower),
                "C" => Base.encode16(:crypto.strong_rand_bytes(33), case: :lower),
                "id" => "test01"
              }
            ]
          }
        ]
      }

      encoded = "cashuA" <> Base.url_encode64(Jason.encode!(payload), padding: false)
      assert {:error, :invalid_proof_encoding} = Token.deserialize(encoded)
    end

    test "rejects wrong byte length for secret (not 32 bytes)" do
      payload = %{
        "token" => [
          %{
            "proofs" => [
              %{
                "amount" => 1,
                "secret" => Base.encode16(:crypto.strong_rand_bytes(16), case: :lower),
                "C" => Base.encode16(:crypto.strong_rand_bytes(33), case: :lower),
                "id" => "test01"
              }
            ]
          }
        ]
      }

      encoded = "cashuA" <> Base.url_encode64(Jason.encode!(payload), padding: false)
      assert {:error, :invalid_proof_encoding} = Token.deserialize(encoded)
    end

    test "rejects wrong byte length for C (not 33 bytes)" do
      payload = %{
        "token" => [
          %{
            "proofs" => [
              %{
                "amount" => 1,
                "secret" => Base.encode16(:crypto.strong_rand_bytes(32), case: :lower),
                "C" => Base.encode16(:crypto.strong_rand_bytes(32), case: :lower),
                "id" => "test01"
              }
            ]
          }
        ]
      }

      encoded = "cashuA" <> Base.url_encode64(Jason.encode!(payload), padding: false)
      assert {:error, :invalid_proof_encoding} = Token.deserialize(encoded)
    end
  end
end
