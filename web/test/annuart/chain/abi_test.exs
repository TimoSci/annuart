defmodule Annuart.Chain.AbiTest do
  use ExUnit.Case, async: true
  alias Annuart.Chain.Abi

  defp word(n), do: n |> Integer.to_string(16) |> String.pad_leading(64, "0") |> String.downcase()
  defp pad(n), do: "0x" <> word(n)
  defp pad_addr("0x" <> a), do: "0x" <> String.pad_leading(a, 64, "0")

  @schedule_hex "0x0000000000000000000000000000000000000000000000000000000000000020000000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000003e80000000000000000000000000000000000000000000000000000000000000001"

  test "topics match the contract" do
    assert Abi.topic(:endowment_minted) ==
             "0xd8a9f6d0a9cfd3d40de7bcf9e2ae29a4aafc952ea9b81a96fdab2c63f9c1f205"

    assert Abi.topic(:transfer) ==
             "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef"
  end

  test "decodes an EndowmentMinted log" do
    log = %{
      "topics" => [
        Abi.topic(:endowment_minted),
        pad(7),
        pad_addr("0x00000000000000000000000000000000000c0ffe"),
        pad_addr("0x00000000000000000000000000000000000a11ce")
      ],
      "data" => "0x" <> word(1_700_000_000) <> word(1)
    }

    assert {:minted,
            %{
              token_id: 7,
              creator: "0x00000000000000000000000000000000000c0ffe",
              to: "0x00000000000000000000000000000000000a11ce",
              schedule_start: 1_700_000_000,
              top_ups_allowed: true
            }} = Abi.decode_log(log)
  end

  test "decodes a Transfer log" do
    log = %{
      "topics" => [
        Abi.topic(:transfer),
        pad_addr("0x00000000000000000000000000000000000a11ce"),
        pad_addr("0x00000000000000000000000000000000000b0b00"),
        pad(9)
      ],
      "data" => "0x"
    }

    assert {:transfer,
            %{
              from: "0x00000000000000000000000000000000000a11ce",
              to: "0x00000000000000000000000000000000000b0b00",
              token_id: 9
            }} = Abi.decode_log(log)
  end

  test "decodes scheduleOf result" do
    assert Abi.decode_result(:schedule_of, @schedule_hex) == [%{duration: 1000, rate_per_sec: 1}]
  end

  test "decodes scalar results" do
    assert Abi.decode_result(:decimals, "0x" <> word(6)) == 6
    assert Abi.decode_result(:settled_of, "0x" <> word(1)) == true
    assert Abi.decode_result(:schedule_end_of, "0x" <> word(123)) == 123

    assert Abi.decode_result(:owner_of, pad_addr("0x00000000000000000000000000000000000a11ce")) ==
             "0x00000000000000000000000000000000000a11ce"
  end

  test "decodes a dynamic string symbol" do
    hex =
      "0x" <>
        word(32) <> word(4) <> Base.encode16("MOCK", case: :lower) <> String.duplicate("0", 56)

    assert Abi.decode_result(:symbol, hex) == "MOCK"
  end

  test "encodes calls with selector and arguments" do
    assert Abi.encode_call(:schedule_of, [1]) ==
             "0x169cadc9" <> word(1)

    assert Abi.encode_call(:symbol, []) == "0x95d89b41"
    assert Abi.encode_call(:decimals, []) == "0x313ce567"
  end

  test "unknown log" do
    assert Abi.decode_log(%{"topics" => ["0x" <> String.duplicate("00", 32)], "data" => "0x"}) ==
             :unknown
  end
end
