defmodule Annuart.RpcStubTest do
  use ExUnit.Case, async: false
  alias Annuart.RpcStub

  setup do
    RpcStub.reset()
    :ok
  end

  test "serves head, blocks, code and filtered logs" do
    RpcStub.put_head(10)
    RpcStub.put_block(5, %{hash: "0xabc", timestamp: 1000})
    RpcStub.put_code("0xAA", "0x60")

    RpcStub.put_logs([
      %{"address" => "0xaa", "blockNumber" => "0x5", "topics" => ["0x01"]},
      %{"address" => "0xaa", "blockNumber" => "0x9", "topics" => ["0x02"]}
    ])

    assert {:ok, 10} = RpcStub.block_number()
    assert {:ok, %{hash: "0xabc", timestamp: 1000}} = RpcStub.block(5)
    assert {:error, :not_found} = RpcStub.block(6)
    assert {:ok, "0x60"} = RpcStub.get_code("0xaa")
    assert {:ok, "0x"} = RpcStub.get_code("0xbb")

    filter = %{address: "0xAA", from_block: 0, to_block: 6, topics: [["0x01", "0x02"]]}
    assert {:ok, [%{"blockNumber" => "0x5"}]} = RpcStub.get_logs(filter)

    assert {:ok, [%{"blockNumber" => "0x9"}]} =
             RpcStub.get_logs(%{filter | from_block: 7, to_block: 9, topics: ["0x02"]})
  end

  test "reset clears state" do
    RpcStub.put_head(3)
    RpcStub.reset()
    assert {:ok, 0} = RpcStub.block_number()
  end
end
