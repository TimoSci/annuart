defmodule Annuart.Chain.ReaderTest do
  # The RpcStub is global state, so these tests cannot run concurrently.
  use ExUnit.Case, async: false
  alias Annuart.Chain.{Abi, Reader}
  alias Annuart.RpcStub

  @nft "0x00000000000000000000000000000000000000aa"
  @token "0x00000000000000000000000000000000000000bb"
  @schedule_hex "0x0000000000000000000000000000000000000000000000000000000000000020000000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000003e80000000000000000000000000000000000000000000000000000000000000001"

  defp word(n), do: n |> Integer.to_string(16) |> String.pad_leading(64, "0")

  setup do
    RpcStub.reset()
    :ok
  end

  test "schedule is :hidden when the call reverts" do
    RpcStub.put_call(@nft, Abi.encode_call(:schedule_of, [7]), {:error, {:revert, "0x"}})
    assert Reader.schedule(@nft, 7) == {:error, :hidden}
  end

  test "schedule is :hidden when the function does not exist (empty return data)" do
    RpcStub.put_call(@nft, Abi.encode_call(:schedule_of, [7]), {:ok, "0x"})
    assert Reader.schedule(@nft, 7) == {:error, :hidden}
  end

  test "schedule decodes via the stub" do
    RpcStub.put_call(@nft, Abi.encode_call(:schedule_of, [7]), {:ok, @schedule_hex})
    assert Reader.schedule(@nft, 7) == {:ok, [%{duration: 1000, rate_per_sec: 1}]}
  end

  test "schedule passes other errors through" do
    RpcStub.put_call(@nft, Abi.encode_call(:schedule_of, [7]), {:error, :timeout})
    assert Reader.schedule(@nft, 7) == {:error, :timeout}
  end

  test "last_accrual_at, schedule_end and settled" do
    RpcStub.put_call(@nft, Abi.encode_call(:last_accrual_at_of, [7]), {:ok, "0x" <> word(50)})
    RpcStub.put_call(@nft, Abi.encode_call(:schedule_end_of, [7]), {:ok, "0x" <> word(99)})
    RpcStub.put_call(@nft, Abi.encode_call(:settled_of, [7]), {:ok, "0x" <> word(0)})

    assert Reader.last_accrual_at(@nft, 7) == {:ok, 50}
    assert Reader.schedule_end(@nft, 7) == {:ok, 99}
    assert Reader.settled(@nft, 7) == {:ok, false}
  end

  test "token_meta" do
    symbol =
      "0x" <>
        word(32) <> word(4) <> Base.encode16("MOCK", case: :lower) <> String.duplicate("0", 56)

    RpcStub.put_call(@token, Abi.encode_call(:symbol, []), {:ok, symbol})
    RpcStub.put_call(@token, Abi.encode_call(:decimals, []), {:ok, "0x" <> word(6)})

    assert Reader.token_meta(@token) == {:ok, %{symbol: "MOCK", decimals: 6}}
  end

  describe "token_meta cache" do
    @token2 "0x00000000000000000000000000000000000000cc"

    setup do
      previous = Application.fetch_env(:annuart, :cache_token_meta)
      previous_chain = Application.fetch_env(:annuart, :chain)
      Application.put_env(:annuart, :cache_token_meta, true)
      Application.put_env(:annuart, :chain, chain_id: 1, rpc_url: "x", contracts: [])
      clear_cache()

      on_exit(fn ->
        clear_cache()

        for {k, v} <- [cache_token_meta: previous, chain: previous_chain] do
          case v do
            {:ok, val} -> Application.put_env(:annuart, k, val)
            :error -> Application.delete_env(:annuart, k)
          end
        end
      end)
    end

    defp clear_cache do
      for {{Annuart.Chain.Reader, :token_meta, _, _} = key, _} <- :persistent_term.get(),
          do: :persistent_term.erase(key)
    end

    defp seed_meta(token) do
      symbol =
        "0x" <>
          word(32) <> word(4) <> Base.encode16("MOCK", case: :lower) <> String.duplicate("0", 56)

      RpcStub.put_call(token, Abi.encode_call(:symbol, []), {:ok, symbol})
      RpcStub.put_call(token, Abi.encode_call(:decimals, []), {:ok, "0x" <> word(6)})
    end

    defp calls_to(token), do: Enum.count(RpcStub.eth_calls(), fn {to, _} -> to == token end)

    test "two calls for one token read the chain once" do
      seed_meta(@token)
      assert {:ok, %{symbol: "MOCK", decimals: 6}} = Reader.token_meta(@token)
      assert {:ok, %{symbol: "MOCK", decimals: 6}} = Reader.token_meta(@token)

      calls = RpcStub.eth_calls()
      assert Enum.count(calls, &(&1 == {@token, Abi.encode_call(:symbol, [])})) == 1
      assert Enum.count(calls, &(&1 == {@token, Abi.encode_call(:decimals, [])})) == 1
    end

    test "an error is not cached" do
      assert {:error, _} = Reader.token_meta(@token2)
      first = calls_to(@token2)

      seed_meta(@token2)
      assert {:ok, %{decimals: 6}} = Reader.token_meta(@token2)
      assert calls_to(@token2) > first
    end

    test "a different chain id does not share the entry" do
      seed_meta(@token)
      assert {:ok, _} = Reader.token_meta(@token)
      before = calls_to(@token)

      Application.put_env(:annuart, :chain, chain_id: 2, rpc_url: "x", contracts: [])
      assert {:ok, _} = Reader.token_meta(@token)
      assert calls_to(@token) == before * 2
    end
  end
end
