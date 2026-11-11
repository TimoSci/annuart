defmodule Annuart.Chain.RpcTest do
  # Changes application env, so not async.
  use ExUnit.Case, async: false

  alias Annuart.Chain.Rpc

  setup do
    previous = Application.fetch_env(:annuart, :rpc_req_options)
    Application.put_env(:annuart, :rpc_req_options, plug: {Req.Test, Rpc})

    on_exit(fn ->
      case previous do
        {:ok, v} -> Application.put_env(:annuart, :rpc_req_options, v)
        :error -> Application.delete_env(:annuart, :rpc_req_options)
      end
    end)
  end

  defp reply(json), do: Req.Test.stub(Rpc, fn conn -> Req.Test.json(conn, json) end)

  test "a JSON-RPC error with revert data is a revert" do
    reply(%{
      "jsonrpc" => "2.0",
      "id" => 1,
      "error" => %{"code" => 3, "message" => "execution reverted", "data" => "0x08c379a0"}
    })

    assert Rpc.eth_call("0xaa", "0x01") == {:error, {:revert, "0x08c379a0"}}
  end

  test "an HTTP 429 is an http error" do
    Req.Test.stub(Rpc, fn conn -> Plug.Conn.send_resp(conn, 429, "slow down") end)
    assert Rpc.block_number() == {:error, {:http, 429}}
  end

  test "an HTTP 200 whose body is not a JSON object is an http error" do
    Req.Test.stub(Rpc, fn conn -> Plug.Conn.send_resp(conn, 200, "<html>gateway</html>") end)
    assert Rpc.block_number() == {:error, {:http, 200}}
  end

  test "a block that does not exist is :not_found" do
    reply(%{"jsonrpc" => "2.0", "id" => 1, "result" => nil})
    assert Rpc.block(123) == {:error, :not_found}
  end

  test "hex quantities decode to integers" do
    reply(%{"jsonrpc" => "2.0", "id" => 1, "result" => "0x1b4"})
    assert Rpc.block_number() == {:ok, 436}

    reply(%{
      "jsonrpc" => "2.0",
      "id" => 1,
      "result" => %{"hash" => "0xabc", "timestamp" => "0x6553f100"}
    })

    assert Rpc.block(1) == {:ok, %{hash: "0xabc", timestamp: 0x6553F100}}
  end

  test "a transport error is returned, not raised" do
    Req.Test.stub(Rpc, fn conn -> Req.Test.transport_error(conn, :econnrefused) end)
    assert {:error, %Req.TransportError{reason: :econnrefused}} = Rpc.block_number()
  end
end
