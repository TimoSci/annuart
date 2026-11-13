defmodule Annuart.EnftsTest do
  # get_enft resolves a label through the chain config, which is application
  # env: not async.
  use Annuart.DataCase, async: false

  alias Annuart.Chain.Config
  alias Annuart.Enfts
  alias Annuart.Enfts.{Cursor, Enft, Payout, Transfer}

  @nft_a "0x" <> String.duplicate("a1", 20)
  @nft_b "0x" <> String.duplicate("b2", 20)
  # A contract that is no longer in the deployment file.
  @nft_gone "0x" <> String.duplicate("dd", 20)

  @alice "0x" <> String.duplicate("ab", 20)
  @bob "0x" <> String.duplicate("cd", 20)
  @max 18_446_744_073_709_551_615

  setup do
    previous = Application.fetch_env!(:annuart, :chain)
    on_exit(fn -> Application.put_env(:annuart, :chain, previous) end)

    contract = fn label, nft ->
      %Config.Contract{label: label, nft: nft, token: nft, token_kind: :mock, deploy_block: 0}
    end

    Application.put_env(
      :annuart,
      :chain,
      Keyword.put(previous, :contracts, [contract.("Alpha", @nft_a), contract.("Beta", @nft_b)])
    )

    :ok
  end

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

  test "get_enft looks up the configured contract's address, so a stale row under the same label is not found" do
    # Left by an earlier deployment that used the label "Alpha" at another address.
    {:ok, _} = Enfts.record_mint(mint_attrs(nft: @nft_gone, token_id: 1, owner: @bob))
    {:ok, current} = Enfts.record_mint(mint_attrs(token_id: 1))

    assert %Enft{id: id, nft: @nft_a} = Enfts.get_enft("Alpha", 1)
    assert id == current.id
  end

  test "get_enft is nil for a label that is not configured, even with rows under it" do
    {:ok, _} = Enfts.record_mint(mint_attrs(label: "Gamma", nft: @nft_gone, token_id: 1))
    assert Enfts.get_enft("Gamma", 1) == nil
  end

  test "delete_unconfigured removes the enfts, transfers and cursors of other contracts only" do
    {:ok, _} = Enfts.record_mint(mint_attrs(token_id: 1))
    {:ok, gone} = Enfts.record_mint(mint_attrs(nft: @nft_gone, token_id: 1))
    :ok = Enfts.record_transfer(transfer_attrs([]))

    :ok =
      Enfts.record_transfer(
        transfer_attrs(nft: @nft_gone, tx_hash: "0x" <> String.duplicate("09", 32))
      )

    :ok = Enfts.put_cursor(@nft_a, 50, "0xhashA")
    :ok = Enfts.put_cursor(@nft_gone, 70, "0xhashGone")

    assert Enfts.delete_unconfigured([@nft_a, @nft_b]) == true

    assert Repo.get(Enft, gone.id) == nil
    assert [%Enft{nft: @nft_a}] = Repo.all(Enft)
    assert [%Transfer{}] = Repo.all(Transfer)
    assert Enfts.cursor(@nft_gone) == nil
    assert %Cursor{last_block: 50} = Enfts.cursor(@nft_a)

    # Nothing left to remove.
    assert Enfts.delete_unconfigured([@nft_a, @nft_b]) == false
    # Addresses compare case-insensitively.
    assert Enfts.delete_unconfigured([String.upcase(@nft_a)]) == false
    assert [%Enft{}] = Repo.all(Enft)
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

  describe "automatic payouts" do
    @req1 "0x" <> String.duplicate("01", 32)
    @req2 "0x" <> String.duplicate("02", 32)
    @wei 10_000_000_000_000_000_000_000_000

    setup do
      {:ok, enft} = Enfts.record_mint(mint_attrs([]))
      %{enft: enft}
    end

    defp settings(overrides) do
      Map.merge(
        %{nft: @nft_a, token_id: 1, enabled: true, interval: 86_400, fee: 1_000},
        Map.new(overrides)
      )
    end

    defp requested(overrides \\ []) do
      Map.merge(
        %{
          nft: @nft_a,
          token_id: 1,
          request_id: @req1,
          recipient: @alice,
          requester: @bob,
          fee_offered: 1_000,
          requested_at: ~U[2026-01-03 00:00:00Z],
          requested_block: 20
        },
        Map.new(overrides)
      )
    end

    defp paid(overrides \\ []) do
      Map.merge(
        %{
          nft: @nft_a,
          token_id: 1,
          request_id: @req1,
          amount_wei: @wei,
          fee_wei: 1_000,
          paid_in_weth: false,
          paid_at: ~U[2026-01-03 00:01:00Z],
          paid_block: 21,
          tx_hash: "0x" <> String.duplicate("0a", 32)
        },
        Map.new(overrides)
      )
    end

    test "a standard ENFT has no automatic settings", %{enft: enft} do
      assert enft.auto_enabled == nil and enft.auto_interval == nil
      assert enft.auto_fee == nil and enft.pending_request_id == nil
    end

    test "record_auto_settings stores and replaces the settings" do
      assert :ok = Enfts.record_auto_settings(settings(fee: @wei))
      assert :ok = Enfts.record_auto_settings(settings(fee: @wei))

      assert %Enft{auto_enabled: true, auto_interval: 86_400, auto_fee: @wei} =
               Enfts.get_enft("Alpha", 1)

      assert :ok = Enfts.record_auto_settings(settings(enabled: false, interval: 60, fee: 0))

      assert %Enft{auto_enabled: false, auto_interval: 60, auto_fee: 0} =
               Enfts.get_enft("Alpha", 1)
    end

    test "settings for an ENFT that is not stored are ignored" do
      assert :ok = Enfts.record_auto_settings(settings(token_id: 99))
      assert Repo.aggregate(Enft, :count) == 1
    end

    test "a request then its payment fill one row", %{enft: enft} do
      :ok = Enfts.record_payout_requested(requested())
      assert [%Payout{paid_at: nil, fee_offered: 1_000}] = Enfts.list_payouts(enft)
      assert Enfts.last_payout(enft) == nil

      :ok = Enfts.record_payout_paid(paid(paid_in_weth: true))

      assert [
               %Payout{
                 request_id: @req1,
                 recipient: @alice,
                 requester: @bob,
                 fee_offered: 1_000,
                 requested_block: 20,
                 amount_wei: @wei,
                 fee_wei: 1_000,
                 paid_in_weth: true,
                 paid_block: 21
               }
             ] = Enfts.list_payouts(enft)

      assert %Payout{request_id: @req1} = Enfts.last_payout(enft)
    end

    test "a payment whose request was never seen creates one row", %{enft: enft} do
      :ok = Enfts.record_payout_paid(paid())

      assert [%Payout{request_id: @req1, amount_wei: @wei, recipient: nil}] =
               Enfts.list_payouts(enft)
    end

    test "replaying a request and its payment changes nothing", %{enft: enft} do
      for _ <- 1..2 do
        :ok = Enfts.record_payout_requested(requested())
        :ok = Enfts.record_payout_paid(paid())
      end

      assert Repo.aggregate(Payout, :count) == 1
      assert [%Payout{amount_wei: @wei, recipient: @alice}] = Enfts.list_payouts(enft)
      assert Enfts.get_enft("Alpha", 1).pending_request_id == nil
    end

    test "a request sets the pending request and its payment clears it" do
      :ok = Enfts.record_payout_requested(requested())
      assert Enfts.get_enft("Alpha", 1).pending_request_id == @req1

      :ok = Enfts.record_payout_paid(paid())
      assert Enfts.get_enft("Alpha", 1).pending_request_id == nil
    end

    test "a payment does not clear a different pending request" do
      :ok = Enfts.record_payout_requested(requested(request_id: @req2))
      :ok = Enfts.record_payout_paid(paid(request_id: @req1))
      assert Enfts.get_enft("Alpha", 1).pending_request_id == @req2
    end

    test "list_payouts is newest first and last_payout is the latest paid", %{enft: enft} do
      :ok = Enfts.record_payout_requested(requested())
      :ok = Enfts.record_payout_paid(paid())
      :ok = Enfts.record_payout_requested(requested(request_id: @req2, requested_block: 30))

      assert [%{request_id: @req2}, %{request_id: @req1}] = Enfts.list_payouts(enft)
      assert %Payout{request_id: @req1} = Enfts.last_payout(enft)
    end

    test "reset_contract deletes payouts" do
      :ok = Enfts.record_payout_requested(requested())
      :ok = Enfts.reset_contract(@nft_a)
      assert Repo.aggregate(Payout, :count) == 0
    end

    test "amounts above the signed 64-bit range survive a round trip", %{enft: enft} do
      :ok = Enfts.record_payout_paid(paid(amount_wei: @wei))
      assert [%Payout{amount_wei: @wei}] = Enfts.list_payouts(enft)
    end
  end
end
