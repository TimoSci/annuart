defmodule Annuart.EnftsTest do
  use Annuart.DataCase, async: true

  alias Annuart.Enfts
  alias Annuart.Enfts.{Cursor, Enft, Transfer}

  @nft_a "0x" <> String.duplicate("a1", 20)
  @nft_b "0x" <> String.duplicate("b2", 20)
  @alice "0x" <> String.duplicate("ab", 20)
  @bob "0x" <> String.duplicate("cd", 20)
  @max 18_446_744_073_709_551_615

  defp mint_attrs(overrides) do
    Map.merge(
      %{
        label: "Alpha",
        nft: @nft_a,
        token_id: 1,
        creator: @alice,
        owner: @alice,
        created_at: ~U[2026-01-01 00:00:00Z],
        created_block: 10,
        schedule_start: 1_700_000_000,
        top_ups_allowed: false,
        schedule: [%{"duration" => 100, "rate_per_sec" => 2}]
      },
      Map.new(overrides)
    )
  end

  defp transfer_attrs(overrides) do
    Map.merge(
      %{
        nft: @nft_a,
        token_id: 1,
        from: @alice,
        to: @bob,
        block_number: 11,
        log_index: 0,
        tx_hash: "0x" <> String.duplicate("01", 32),
        at: ~U[2026-01-02 00:00:00Z]
      },
      Map.new(overrides)
    )
  end

  test "record_mint is idempotent and record_transfer moves the owner" do
    assert {:ok, %Enft{id: id, owner: @alice, token_id: 1}} = Enfts.record_mint(mint_attrs([]))
    assert {:ok, %Enft{id: ^id}} = Enfts.record_mint(mint_attrs([]))
    assert Repo.aggregate(Enft, :count) == 1

    assert :ok = Enfts.record_transfer(transfer_attrs([]))
    assert :ok = Enfts.record_transfer(transfer_attrs([]))

    enft = Enfts.get_enft("Alpha", 1)
    assert enft.owner == @bob

    assert [%Transfer{from: @alice, to: @bob, block_number: 11, log_index: 0}] =
             Enfts.history(enft)

    assert Repo.aggregate(Transfer, :count) == 1
  end

  test "history is ordered oldest first" do
    {:ok, enft} = Enfts.record_mint(mint_attrs([]))

    t2 =
      transfer_attrs(
        block_number: 12,
        log_index: 1,
        tx_hash: "0x" <> String.duplicate("02", 32),
        from: @bob,
        to: @alice
      )

    t1 =
      transfer_attrs(block_number: 11, log_index: 3, tx_hash: "0x" <> String.duplicate("03", 32))

    :ok = Enfts.record_transfer(t2)
    :ok = Enfts.record_transfer(t1)

    assert [%{block_number: 11}, %{block_number: 12}] = Enfts.history(enft)
  end

  test "list_enfts filters by top_ups and label and sorts by created_at" do
    {:ok, a} = Enfts.record_mint(mint_attrs(token_id: 1, created_at: ~U[2026-01-01 00:00:00Z]))

    {:ok, b} =
      Enfts.record_mint(
        mint_attrs(token_id: 2, top_ups_allowed: true, created_at: ~U[2026-01-02 00:00:00Z])
      )

    {:ok, c} =
      Enfts.record_mint(
        mint_attrs(
          label: "Beta",
          nft: @nft_b,
          token_id: 1,
          top_ups_allowed: true,
          created_at: ~U[2026-01-03 00:00:00Z]
        )
      )

    ids = fn list -> Enum.map(list, & &1.id) end

    assert ids.(Enfts.list_enfts([])) == [c.id, b.id, a.id]
    assert ids.(Enfts.list_enfts(sort: :oldest)) == [a.id, b.id, c.id]
    assert ids.(Enfts.list_enfts(top_ups: true)) == [c.id, b.id]
    assert ids.(Enfts.list_enfts(top_ups: false)) == [a.id]
    assert ids.(Enfts.list_enfts(top_ups: nil)) == [c.id, b.id, a.id]
    assert ids.(Enfts.list_enfts(label: "Alpha")) == [b.id, a.id]
    assert ids.(Enfts.list_enfts(label: "Alpha", top_ups: true, sort: :oldest)) == [b.id]
  end

  test "get_enft finds by label and token id" do
    {:ok, a} = Enfts.record_mint(mint_attrs([]))
    assert %Enft{id: id} = Enfts.get_enft("Alpha", 1)
    assert id == a.id
    assert Enfts.get_enft("Alpha", 2) == nil
    assert Enfts.get_enft("Nope", 1) == nil
  end

  test "list_owned is case-insensitive on the address" do
    {:ok, a} = Enfts.record_mint(mint_attrs(token_id: 1, owner: @alice))
    {:ok, _} = Enfts.record_mint(mint_attrs(token_id: 2, owner: @bob))

    upper = "0x" <> String.upcase(String.trim_leading(@alice, "0x"))
    assert [%Enft{id: id}] = Enfts.list_owned(upper)
    assert id == a.id
    assert [%Enft{id: ^id}] = Enfts.list_owned(@alice)
    assert Enfts.list_owned("0x" <> String.duplicate("ee", 20)) == []
  end

  test "reset_contract removes that contract's enfts, transfers and cursor only" do
    {:ok, _} = Enfts.record_mint(mint_attrs(token_id: 1))
    {:ok, _} = Enfts.record_mint(mint_attrs(label: "Beta", nft: @nft_b, token_id: 1))
    :ok = Enfts.record_transfer(transfer_attrs([]))

    :ok =
      Enfts.record_transfer(
        transfer_attrs(nft: @nft_b, tx_hash: "0x" <> String.duplicate("09", 32))
      )

    :ok = Enfts.put_cursor(@nft_a, 50, "0xhashA")
    :ok = Enfts.put_cursor(@nft_b, 60, "0xhashB")

    assert :ok = Enfts.reset_contract(@nft_a)

    assert Enfts.get_enft("Alpha", 1) == nil
    assert %Enft{nft: @nft_b} = beta = Enfts.get_enft("Beta", 1)
    assert [%Transfer{}] = Enfts.history(beta)
    assert Repo.aggregate(Transfer, :count) == 1
    assert Enfts.cursor(@nft_a) == nil
    assert %Cursor{last_block: 60, last_block_hash: "0xhashB"} = Enfts.cursor(@nft_b)
  end

  test "put_cursor inserts then updates" do
    assert Enfts.cursor(@nft_a) == nil
    :ok = Enfts.put_cursor(@nft_a, 5, "0xaa")
    :ok = Enfts.put_cursor(@nft_a, 9, "0xbb")
    assert %Cursor{last_block: 9, last_block_hash: "0xbb"} = Enfts.cursor(@nft_a)
    assert Repo.aggregate(Cursor, :count) == 1
  end

  test "an enft with schedule nil round-trips" do
    {:ok, _} = Enfts.record_mint(mint_attrs(schedule: nil))
    assert %Enft{schedule: nil} = Enfts.get_enft("Alpha", 1)
  end

  test "a schedule with the indefinite sentinel round-trips exactly" do
    segs = [
      %{"duration" => 100, "rate_per_sec" => 2},
      %{"duration" => @max, "rate_per_sec" => 3}
    ]

    {:ok, _} = Enfts.record_mint(mint_attrs(schedule: segs))
    assert %Enft{schedule: ^segs} = Enfts.get_enft("Alpha", 1)
    assert Annuart.Schedule.indefinite?(Enfts.get_enft("Alpha", 1).schedule)
  end

  test "a schedule_start above the signed 64-bit range is stored exactly" do
    start = 18_446_744_073_709_551_614

    assert {:ok, %Enft{schedule_start: ^start}} =
             Enfts.record_mint(mint_attrs(schedule_start: start))

    assert %Enft{schedule_start: ^start} = Enfts.get_enft("Alpha", 1)
    assert [%Enft{schedule_start: ^start}] = Enfts.list_enfts([])
  end

  test "record_mint lowercases addresses and accepts atom-keyed segments" do
    upper = "0x" <> String.upcase(String.trim_leading(@alice, "0x"))

    {:ok, enft} =
      Enfts.record_mint(
        mint_attrs(owner: upper, creator: upper, schedule: [%{duration: 5, rate_per_sec: 1}])
      )

    assert enft.owner == @alice
    assert enft.creator == @alice
    assert enft.schedule == [%{"duration" => 5, "rate_per_sec" => 1}]
  end
end
