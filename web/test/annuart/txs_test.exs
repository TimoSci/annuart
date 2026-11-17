defmodule Annuart.TxsTest do
  use Annuart.DataCase, async: false

  alias Annuart.Chain.{Abi, Config}
  alias Annuart.{Enfts, Txs}

  @nft "0x" <> String.duplicate("a1", 20)
  @nft2 "0x" <> String.duplicate("a2", 20)
  @token "0x" <> String.duplicate("b2", 20)
  @alice "0x" <> String.duplicate("ab", 20)
  @bob "0x" <> String.duplicate("cd", 20)
  @carol "0x" <> String.duplicate("ce", 20)
  @contract %Config.Contract{
    label: "wrapped",
    nft: @nft,
    token: @token,
    token_kind: :wrapped,
    deploy_block: 0
  }

  defp word(n), do: String.pad_leading(Integer.to_string(n, 16), 64, "0")
  defp pad("0x" <> hex), do: "0x" <> String.pad_leading(hex, 64, "0")

  defp what(to, input, logs \\ []),
    do: Txs.describe(@contract, %{from: @alice, to: to, input: input}, logs)

  defp mint(token_id, owner) do
    {:ok, enft} =
      Enfts.record_mint(%{
        label: "wrapped",
        nft: @nft,
        token_id: token_id,
        creator: @alice,
        owner: owner,
        created_at: ~U[2026-11-12 14:03:00Z],
        created_block: 1,
        schedule_start: 1,
        top_ups_allowed: true,
        schedule: nil
      })

    enft
  end

  test "names a transaction by the function it called, on the contract or on its token" do
    assert %{kind: "claim", token_id: 7, amount: nil} = what(@nft, "0x379607f5" <> word(7))

    assert %{kind: "transfer", token_id: 9} =
             what(@nft, "0x42842e0e" <> word(1) <> word(2) <> word(9))

    assert %{kind: "authorise", token_id: nil} =
             what(@token, "0xd4febb96" <> word(1) <> word(2))

    assert %{kind: "unwrap_request"} =
             what(@token, "0xe8c15fd4" <> word(1) <> word(2) <> word(3))

    # The same selector means nothing on the other contract, or anywhere else.
    assert %{kind: "other"} = what(@token, "0x379607f5" <> word(7))
    assert %{kind: "other"} = what(@carol, "0x379607f5" <> word(7))
    assert %{kind: "other", token_id: nil} = what(@nft, "0x")
  end

  test "a private-rate create is named by its selector and takes its token id from the mint log" do
    minted = %{
      "topics" => [
        Abi.topic(:endowment_minted),
        "0x" <> word(7),
        pad(@alice),
        pad(@alice)
      ],
      "data" => "0x" <> word(1_700_000_000) <> word(1) <> word(0)
    }

    assert %{kind: "create_private", token_id: 7} =
             what(@nft, "0x16a610e7" <> word(1), [minted])

    assert Txs.private?("create_private")
  end

  test "keeps only the amounts the chain shows in the clear" do
    assert %{kind: "wrap", amount: 5_000, amount_unit: "wei"} =
             what(@token, "0xbf376c7a" <> word(1) <> word(5_000))

    assert %{kind: "unwrap_finalise", amount: 12, amount_unit: "token"} =
             what(@token, "0x5bb67a05" <> word(1) <> word(12))

    assert %{kind: "donate", amount: nil, amount_unit: nil} =
             what(@nft, "0x022d6bc2" <> word(3) <> word(99))

    assert Txs.private?("donate") and Txs.private?("create") and not Txs.private?("wrap")
  end

  test "a paid automatic payout carries the amount of its PayoutPaid event and involves the recipient" do
    enft = mint(4, @bob)
    request_id = "0x" <> String.duplicate("0b", 32)

    :ok =
      Enfts.record_payout_requested(%{
        nft: @nft,
        token_id: 4,
        request_id: request_id,
        recipient: @bob,
        requester: @carol,
        fee_offered: 0,
        requested_at: ~U[2026-11-13 10:00:00Z],
        requested_block: 5
      })

    paid = %{
      "address" => @nft,
      "topics" => [Abi.topic(:payout_paid), "0x" <> word(4), request_id],
      "data" => "0x" <> word(7_000) <> word(0) <> word(0)
    }

    d = what(@nft, "0x3210bfc2" <> word(4) <> word(7), [paid])
    assert %{kind: "payout_finalise", token_id: 4, amount: 7_000, amount_unit: "wei"} = d
    assert Enum.sort(d.parties) == Enum.sort([@alice, @bob])
    assert enft.owner == @bob
  end

  test "the people involved are the sender, the addresses in indexed arguments and a donation's owner" do
    mint(3, @bob)

    transfer = %{
      "topics" => [
        "0x" <> String.duplicate("c7", 32),
        pad(@alice),
        pad(@nft),
        "0x" <> String.duplicate("9f", 32)
      ]
    }

    d = what(@nft, "0x022d6bc2" <> word(3), [transfer])
    # Neither the contract itself nor the encrypted amount's handle is a person.
    assert Enum.sort(d.parties) == Enum.sort([@alice, @bob])

    # A token id in an indexed argument is not an address.
    minted = %{
      "topics" => [
        Abi.topic(:transfer),
        pad("0x" <> String.duplicate("00", 20)),
        pad(@carol),
        "0x" <> word(5)
      ]
    }

    assert Enum.sort(what(@nft, "0x", [minted]).parties) == Enum.sort([@alice, @carol])
  end

  defp record(overrides) do
    :ok =
      Txs.record(
        Map.merge(
          %{
            nft: @nft,
            label: "wrapped",
            tx_hash: "0x" <> String.duplicate("11", 32),
            block_number: 10,
            tx_index: 0,
            at: ~U[2026-11-13 10:00:00Z],
            from: @alice,
            to: @token,
            kind: "wrap",
            token_id: nil,
            amount: 5,
            amount_unit: "wei",
            parties: [@alice]
          },
          Map.new(overrides)
        )
      )
  end

  test "list_for returns an address's transactions newest first, each once" do
    record(%{})

    record(%{
      tx_hash: "0x" <> String.duplicate("22", 32),
      block_number: 11,
      kind: "claim",
      to: @nft2,
      parties: [@alice, @bob]
    })

    # The same transaction seen by the sync of a second contract sharing the token.
    record(%{
      tx_hash: "0x" <> String.duplicate("22", 32),
      block_number: 11,
      kind: "other",
      nft: @nft2,
      label: "auto",
      to: @nft2,
      parties: [@alice, @bob]
    })

    record(%{
      tx_hash: "0x" <> String.duplicate("33", 32),
      block_number: 11,
      tx_index: 4,
      parties: [@carol]
    })

    # Recording again changes nothing.
    record(%{})

    assert [%{block_number: 11, label: "auto"}, %{block_number: 10, kind: "wrap", amount: 5}] =
             Txs.list_for(String.upcase(@alice, :ascii) |> String.replace("0X", "0x"))

    assert [%{label: "auto"}] = Txs.list_for(@bob)
    assert Txs.list_for("0x" <> String.duplicate("77", 20)) == []
    assert [_] = Txs.list_for(@alice, 1)

    assert Txs.delete_unconfigured([@nft]) == 1
    assert [%{block_number: 11, label: "wrapped"}, _] = Txs.list_for(@alice)
  end
end
