defmodule Annuart.IndexerTest do
  # The stub is global state, so these tests cannot run concurrently.
  use Annuart.DataCase, async: false

  import ExUnit.CaptureLog

  alias Annuart.{Enfts, Indexer, RpcStub}
  alias Annuart.Chain.{Abi, Config.Contract}

  @nft "0x" <> String.duplicate("a1", 20)
  @token "0x" <> String.duplicate("b2", 20)
  @nft2 "0x" <> String.duplicate("a2", 20)
  @alice "0x" <> String.duplicate("ab", 20)
  @bob "0x" <> String.duplicate("cd", 20)
  @creator "0x" <> String.duplicate("ee", 20)
  @zero "0x" <> String.duplicate("00", 20)
  @schedule_data "0x" <> String.duplicate("00", 32)

  setup do
    RpcStub.reset()
    put_contracts([contract("mock", @nft, 5)])

    on_exit(fn ->
      Application.put_env(:annuart, :chain,
        chain_id: 31337,
        rpc_url: "http://127.0.0.1:8545",
        contracts: []
      )

      RpcStub.reset()
    end)
  end

  defp contract(label, nft, deploy_block),
    do: %Contract{
      label: label,
      nft: nft,
      token: @token,
      token_kind: :mock,
      deploy_block: deploy_block
    }

  defp put_contracts(contracts, chain_id \\ 31337) do
    Application.put_env(:annuart, :chain,
      chain_id: chain_id,
      rpc_url: "http://127.0.0.1:8545",
      contracts: contracts
    )

    for c <- contracts, do: RpcStub.put_code(c.nft, "0x6080")
  end

  defp pad_topic("0x" <> hex), do: "0x" <> String.pad_leading(hex, 64, "0")
  defp uint_topic(n), do: "0x" <> String.pad_leading(Integer.to_string(n, 16), 64, "0")

  defp hex(n), do: "0x" <> Integer.to_string(n, 16)

  defp mint_log(nft, id, to, block, index, opts \\ []) do
    start = Keyword.get(opts, :start, 1_700_000_000)
    top_ups = Keyword.get(opts, :top_ups, true)
    name = Keyword.get(opts, :name, "")

    data =
      "0x" <>
        String.pad_leading(Integer.to_string(start, 16), 64, "0") <>
        String.pad_leading(if(top_ups, do: "1", else: "0"), 64, "0") <>
        String.pad_trailing(Base.encode16(name, case: :lower), 64, "0")

    %{
      "address" => nft,
      "topics" => [
        Abi.topic(:endowment_minted),
        uint_topic(id),
        pad_topic(@creator),
        pad_topic(to)
      ],
      "data" => data,
      "blockNumber" => hex(block),
      "logIndex" => hex(index),
      "transactionHash" =>
        "0x" <> String.pad_leading(Integer.to_string(block * 100 + index, 16), 64, "0")
    }
  end

  defp transfer_log(nft, id, from, to, block, index) do
    %{
      "address" => nft,
      "topics" => [Abi.topic(:transfer), pad_topic(from), pad_topic(to), uint_topic(id)],
      "data" => "0x",
      "blockNumber" => hex(block),
      "logIndex" => hex(index),
      "transactionHash" =>
        "0x" <> String.pad_leading(Integer.to_string(block * 100 + index, 16), 64, "0")
    }
  end

  @auto "0x" <> String.duplicate("a3", 20)
  @req "0x" <> String.duplicate("0b", 32)

  defp put_auto_contract do
    put_contracts([
      contract("mock", @nft, 5),
      %{contract("auto", @auto, 5) | nft_kind: :auto}
    ])
  end

  defp word(n), do: String.pad_leading(Integer.to_string(n, 16), 64, "0")

  defp log(nft, topics, data, block, index) do
    %{
      "address" => nft,
      "topics" => topics,
      "data" => "0x" <> data,
      "blockNumber" => hex(block),
      "logIndex" => hex(index),
      "transactionHash" =>
        "0x" <> String.pad_leading(Integer.to_string(block * 100 + index, 16), 64, "0")
    }
  end

  defp settings_log(nft, id, enabled, interval, fee, block, index) do
    log(
      nft,
      [Abi.topic(:auto_payout_set), uint_topic(id)],
      word(if(enabled, do: 1, else: 0)) <> word(interval) <> word(fee),
      block,
      index
    )
  end

  defp requested_log(nft, id, block, index) do
    log(
      nft,
      [Abi.topic(:payout_requested), uint_topic(id), @req, pad_topic(@alice)],
      String.pad_leading(String.trim_leading(@bob, "0x"), 64, "0") <> word(700),
      block,
      index
    )
  end

  defp paid_log(nft, id, block, index) do
    log(
      nft,
      [Abi.topic(:payout_paid), uint_topic(id), @req],
      word(5_000_000_000_000_000_000_000) <> word(700) <> word(0),
      block,
      index
    )
  end

  describe "automatic payouts" do
    setup do
      put_auto_contract()
      put_blocks(0..30)
      RpcStub.put_head(20)
      put_schedule(@auto, 1, [{1000, 1}])
      :ok
    end

    test "a mint and its AutoPayoutSet in one block give an ENFT with settings" do
      RpcStub.put_logs([
        mint_log(@auto, 1, @alice, 10, 0),
        transfer_log(@auto, 1, @zero, @alice, 10, 1),
        settings_log(@auto, 1, true, 86_400, 1_000, 10, 2)
      ])

      Indexer.sync_once()

      e = Enfts.get_enft("auto", 1)
      assert e.auto_enabled and e.auto_interval == 86_400 and e.auto_fee == 1_000
      assert e.pending_request_id == nil
    end

    test "a transfer then AutoPayoutSet disables automatic payouts" do
      RpcStub.put_logs([
        mint_log(@auto, 1, @alice, 10, 0),
        settings_log(@auto, 1, true, 86_400, 1_000, 10, 2),
        transfer_log(@auto, 1, @alice, @bob, 12, 0),
        settings_log(@auto, 1, false, 86_400, 1_000, 12, 1)
      ])

      Indexer.sync_once()

      e = Enfts.get_enft("auto", 1)
      assert e.owner == @bob and e.auto_enabled == false and e.auto_interval == 86_400
    end

    test "a request in one range and its payment in the next give one paid row" do
      RpcStub.put_logs([
        mint_log(@auto, 1, @alice, 10, 0),
        settings_log(@auto, 1, true, 86_400, 1_000, 10, 1),
        requested_log(@auto, 1, 15, 0)
      ])

      Indexer.sync_once()
      e = Enfts.get_enft("auto", 1)
      assert e.pending_request_id == @req

      assert [%{paid_at: nil, requester: @bob, recipient: @alice, fee_offered: 700}] =
               Enfts.list_payouts(e)

      RpcStub.put_head(25)

      RpcStub.put_logs([
        mint_log(@auto, 1, @alice, 10, 0),
        requested_log(@auto, 1, 15, 0),
        paid_log(@auto, 1, 22, 0)
      ])

      Indexer.sync_once()

      e = Enfts.get_enft("auto", 1)
      assert e.pending_request_id == nil

      assert [
               %{
                 request_id: @req,
                 requested_block: 15,
                 paid_block: 22,
                 amount_wei: 5_000_000_000_000_000_000_000,
                 fee_wei: 700,
                 paid_in_weth: false,
                 requested_at: requested_at,
                 paid_at: paid_at
               }
             ] = Enfts.list_payouts(e)

      assert requested_at == DateTime.from_unix!(1_700_000_015)
      assert paid_at == DateTime.from_unix!(1_700_000_022)
    end

    test "syncing the same ranges again leaves one row" do
      logs = [
        mint_log(@auto, 1, @alice, 10, 0),
        requested_log(@auto, 1, 15, 0),
        paid_log(@auto, 1, 16, 0)
      ]

      RpcStub.put_logs(logs)
      Indexer.sync_once()
      Indexer.sync_once()

      # Rebuild from scratch (the cursor is gone): still one row.
      Enfts.reset_contract(@auto)
      Indexer.sync_once()

      assert Repo.aggregate(Annuart.Enfts.Payout, :count) == 1
      assert [%{paid_block: 16}] = Enfts.list_payouts(Enfts.get_enft("auto", 1))
    end

    test "each event broadcasts enft_changed" do
      RpcStub.put_logs([
        mint_log(@auto, 1, @alice, 10, 0),
        settings_log(@auto, 1, true, 60, 0, 11, 0)
      ])

      Phoenix.PubSub.subscribe(Annuart.PubSub, "enfts")
      Indexer.sync_once()
      assert_receive {:enft_changed, "auto", 1}
      drain_enft_messages()

      RpcStub.put_head(25)
      RpcStub.put_logs([requested_log(@auto, 1, 22, 0)])
      Indexer.sync_once()
      assert_receive {:enft_changed, "auto", 1}
      drain_enft_messages()

      RpcStub.put_head(28)
      RpcStub.put_logs([paid_log(@auto, 1, 27, 0)])
      Indexer.sync_once()
      assert_receive {:enft_changed, "auto", 1}
    end

    test "the three events are ignored on a standard contract" do
      put_schedule(@nft, 1, [{1000, 1}])

      RpcStub.put_logs([
        mint_log(@nft, 1, @alice, 10, 0),
        settings_log(@nft, 1, true, 60, 0, 11, 0),
        requested_log(@nft, 1, 12, 0)
      ])

      Indexer.sync_once()

      e = Enfts.get_enft("mock", 1)
      assert e.auto_enabled == nil and e.pending_request_id == nil
      assert Enfts.list_payouts(e) == []
    end
  end

  defp drain_enft_messages(acc \\ []) do
    receive do
      msg when msg == :enfts_reset or elem(msg, 0) == :enft_changed ->
        drain_enft_messages([msg | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp put_block(n, hash \\ nil),
    do: RpcStub.put_block(n, %{hash: hash || "0xh#{n}", timestamp: 1_700_000_000 + n})

  defp put_blocks(range), do: Enum.each(range, &put_block/1)

  defp put_schedule(nft, id, segments) do
    RpcStub.put_call(
      nft,
      Abi.encode_call(:schedule_of, [id]),
      {:ok, schedule_hex(segments)}
    )
  end

  # ABI encoding of (uint64,uint64)[]: offset, length, then each segment.
  defp schedule_hex(segments) do
    word = fn n -> String.pad_leading(Integer.to_string(n, 16), 64, "0") end

    "0x" <>
      word.(32) <>
      word.(length(segments)) <>
      Enum.map_join(segments, fn {d, r} -> word.(d) <> word.(r) end)
  end

  defp seed_basic do
    put_blocks(0..20)
    RpcStub.put_head(20)
    put_schedule(@nft, 1, [{1000, 1}])

    RpcStub.put_logs([
      mint_log(@nft, 1, @alice, 10, 0),
      # the ERC-721 mint transfer, which the indexer ignores
      transfer_log(@nft, 1, @zero, @alice, 10, 1),
      transfer_log(@nft, 1, @alice, @bob, 15, 0)
    ])
  end

  test "indexes a mint and a transfer" do
    seed_basic()
    Indexer.sync_once()

    e = Enfts.get_enft("mock", 1)
    assert e.owner == @bob and e.creator == @creator and e.top_ups_allowed
    assert e.schedule_start == 1_700_000_000
    assert e.created_block == 10
    assert e.created_at == DateTime.from_unix!(1_700_000_010)
    assert e.schedule == [%{"duration" => 1000, "rate_per_sec" => 1}]
    assert [%{from: @alice, to: @bob, block_number: 15}] = Enfts.history(e)
    assert Enfts.cursor(@nft).last_block == 20
    assert Enfts.cursor(@nft).last_block_hash == "0xh20"
  end

  test "stores the name from the mint, nil when unnamed or not a valid name" do
    put_blocks(0..20)
    RpcStub.put_head(20)
    for id <- 1..3, do: put_schedule(@nft, id, [{1000, 1}])

    RpcStub.put_logs([
      mint_log(@nft, 1, @alice, 10, 0, name: "Rainy day fund"),
      mint_log(@nft, 2, @alice, 11, 0),
      mint_log(@nft, 3, @alice, 12, 0, name: "<b>bold</b>")
    ])

    Indexer.sync_once()

    assert Enfts.get_enft("mock", 1).name == "Rainy day fund"
    assert Enfts.get_enft("mock", 2).name == nil
    # Still indexed: only the name is dropped.
    assert Enfts.get_enft("mock", 3).name == nil
  end

  test "a second pass with no new logs changes nothing and is idempotent" do
    seed_basic()
    Indexer.sync_once()
    before = {Repo.all(Annuart.Enfts.Enft), Repo.all(Annuart.Enfts.Transfer), Enfts.cursor(@nft)}

    Indexer.sync_once()

    assert {Repo.all(Annuart.Enfts.Enft), Repo.all(Annuart.Enfts.Transfer), Enfts.cursor(@nft)} ==
             before

    # New logs after the cursor are picked up on the next pass.
    put_blocks(21..22)
    RpcStub.put_head(22)

    RpcStub.put_logs([
      mint_log(@nft, 1, @alice, 10, 0),
      transfer_log(@nft, 1, @alice, @bob, 15, 0),
      transfer_log(@nft, 1, @bob, @alice, 22, 0)
    ])

    Indexer.sync_once()
    assert Enfts.get_enft("mock", 1).owner == @alice
    assert length(Enfts.history(Enfts.get_enft("mock", 1))) == 2
    assert Enfts.cursor(@nft).last_block == 22
  end

  test "hidden schedule is stored as nil" do
    put_blocks(0..20)
    RpcStub.put_head(20)
    # scheduleOf is not seeded: the stub reverts, as the contract does for a hidden schedule
    RpcStub.put_logs([mint_log(@nft, 1, @alice, 10, 0)])
    Indexer.sync_once()

    e = Enfts.get_enft("mock", 1)
    assert e.schedule == nil
    assert e.owner == @alice
  end

  test "chain restart rebuilds: old enfts gone, new ones present" do
    seed_basic()
    Indexer.sync_once()
    assert Enfts.get_enft("mock", 1)

    # New chain: same height, different block hash at the cursor, different history.
    put_block(20, "0xother")
    put_schedule(@nft, 2, [{5, 5}])
    RpcStub.put_logs([mint_log(@nft, 2, @bob, 7, 0)])
    Phoenix.PubSub.subscribe(Annuart.PubSub, "enfts")
    capture_log(fn -> Indexer.sync_once() end)

    assert Enfts.get_enft("mock", 1) == nil
    assert %{owner: @bob} = Enfts.get_enft("mock", 2)
    assert Enfts.cursor(@nft).last_block_hash == "0xother"

    # :enfts_reset comes after the rebuild: the new ENFT's change message precedes it.
    assert [{:enft_changed, "mock", 2}, :enfts_reset] = drain_enft_messages()
  end

  test "a reset whose rebuild fails is announced once, after a later pass completes it" do
    seed_basic()
    Indexer.sync_once()

    put_block(20, "0xother")
    put_schedule(@nft, 2, [{5, 5}])
    RpcStub.put_logs([mint_log(@nft, 2, @bob, 7, 0)])
    Phoenix.PubSub.subscribe(Annuart.PubSub, "enfts")

    RpcStub.put_error(:get_logs, :econnrefused)
    capture_log(fn -> Indexer.sync_once() end)
    assert Enfts.get_enft("mock", 1) == nil
    assert drain_enft_messages() == []

    RpcStub.clear_error(:get_logs)
    Indexer.sync_once()
    assert [{:enft_changed, "mock", 2}, :enfts_reset] = drain_enft_messages()

    Indexer.sync_once()
    assert drain_enft_messages() == []
  end

  test "rows of a contract no longer configured are removed, and the removal announced once" do
    seed_basic()
    Indexer.sync_once()
    assert %{nft: @nft} = Enfts.get_enft("mock", 1)

    # Redeployed under the same label at a new address, without a node restart.
    put_contracts([contract("mock", @nft2, 5)])
    put_schedule(@nft2, 1, [{7, 7}])
    RpcStub.put_logs([mint_log(@nft2, 1, @bob, 12, 0)])
    Phoenix.PubSub.subscribe(Annuart.PubSub, "enfts")
    Indexer.sync_once()

    assert [%{nft: @nft2, owner: @bob}] = Repo.all(Annuart.Enfts.Enft)
    assert Repo.all(Annuart.Enfts.Transfer) == []
    assert Enfts.cursor(@nft) == nil
    assert %{nft: @nft2} = Enfts.get_enft("mock", 1)
    assert [{:enft_changed, "mock", 1}, :enfts_reset] = drain_enft_messages()

    Indexer.sync_once()
    assert drain_enft_messages() == []
  end

  test "head below cursor triggers a rebuild" do
    seed_basic()
    Indexer.sync_once()

    RpcStub.put_head(8)
    RpcStub.put_logs([mint_log(@nft, 2, @bob, 7, 0)])
    put_blocks(0..8)
    capture_log(fn -> Indexer.sync_once() end)

    assert Enfts.get_enft("mock", 1) == nil
    assert Enfts.get_enft("mock", 2)
    assert Enfts.cursor(@nft).last_block == 8
  end

  test "contract with no code is skipped and others still index" do
    put_contracts([contract("ghost", @nft2, 5), contract("mock", @nft, 5)])
    RpcStub.put_code(@nft2, "0x")
    seed_basic()

    log =
      capture_log(fn -> Indexer.sync_once() end)

    assert log =~ "ghost"
    assert Enfts.cursor(@nft2) == nil
    assert Enfts.get_enft("mock", 1)
  end

  test "contract deployed above head is skipped" do
    put_contracts([contract("mock", @nft, 50)])
    seed_basic()
    log = capture_log(fn -> Indexer.sync_once() end)
    assert log =~ "mock"
    assert Enfts.cursor(@nft) == nil
  end

  test "rpc error leaves the cursor where it was and does not raise" do
    seed_basic()
    Indexer.sync_once()
    assert Enfts.cursor(@nft).last_block == 20

    put_blocks(21..30)
    RpcStub.put_head(30)
    RpcStub.put_error(:get_logs, :econnrefused)

    capture_log(fn -> assert :ok = Indexer.sync_once() end)
    assert Enfts.cursor(@nft).last_block == 20

    RpcStub.put_error(:block_number, :timeout)
    capture_log(fn -> assert :ok = Indexer.sync_once() end)
    assert Enfts.cursor(@nft).last_block == 20
  end

  test "broadcasts enft_changed for each touched enft" do
    seed_basic()
    put_schedule(@nft, 2, [{1, 1}])

    RpcStub.put_logs([
      mint_log(@nft, 1, @alice, 10, 0),
      mint_log(@nft, 2, @alice, 11, 0),
      transfer_log(@nft, 1, @alice, @bob, 15, 0)
    ])

    Phoenix.PubSub.subscribe(Annuart.PubSub, "enfts")
    Indexer.sync_once()

    assert_receive {:enft_changed, "mock", 1}
    assert_receive {:enft_changed, "mock", 2}
    refute_receive {:enft_changed, "mock", 1}
  end

  test "ranges above 2000 blocks are fetched in chunks" do
    put_blocks(0..12_000)
    RpcStub.put_head(12_000)
    put_contracts([contract("mock", @nft, 5)])
    RpcStub.put_logs([mint_log(@nft, 1, @alice, 7_500, 0)])
    Indexer.sync_once()

    queries = RpcStub.log_queries()
    assert length(queries) > 1
    assert Enum.all?(queries, fn {from, to} -> to - from + 1 <= 2_000 end)
    # contiguous, covering deploy block to head
    assert hd(queries) |> elem(0) == 5
    assert List.last(queries) |> elem(1) == 12_000

    assert queries
           |> Enum.chunk_every(2, 1, :discard)
           |> Enum.all?(fn [{_, a}, {b, _}] -> b == a + 1 end)

    assert Enfts.get_enft("mock", 1)
    assert Enfts.cursor(@nft).last_block == 12_000
  end

  test "a log that cannot be decoded is skipped and the cursor still advances" do
    put_blocks(0..20)
    RpcStub.put_head(20)
    put_schedule(@nft, 1, [{1000, 1}])
    bad_hex = put_in(mint_log(@nft, 3, @alice, 12, 0)["data"], "0xzz")
    short = put_in(mint_log(@nft, 4, @alice, 12, 1)["data"], @schedule_data)
    no_index = Map.delete(mint_log(@nft, 5, @alice, 12, 2), "logIndex")

    RpcStub.put_logs([
      mint_log(@nft, 1, @alice, 10, 0),
      bad_hex,
      short,
      no_index,
      transfer_log(@nft, 1, @alice, @bob, 15, 0)
    ])

    log = capture_log(fn -> assert :ok = Indexer.sync_once() end)
    assert log =~ "skipping"

    assert Enfts.get_enft("mock", 1).owner == @bob
    for id <- [3, 4, 5], do: assert(Enfts.get_enft("mock", id) == nil)
    assert Enfts.cursor(@nft).last_block == 20
  end

  describe "confirmation depth" do
    setup do
      previous = Application.fetch_env(:annuart, :indexer_confirmations)
      Application.put_env(:annuart, :indexer_confirmations, 2)

      on_exit(fn ->
        case previous do
          {:ok, v} -> Application.put_env(:annuart, :indexer_confirmations, v)
          :error -> Application.delete_env(:annuart, :indexer_confirmations)
        end
      end)
    end

    test "stays confirmations blocks behind the head" do
      put_contracts([contract("mock", @nft, 90)])
      put_blocks(90..101)
      RpcStub.put_head(100)
      put_schedule(@nft, 1, [{1000, 1}])
      RpcStub.put_logs([mint_log(@nft, 1, @alice, 99, 0)])

      Indexer.sync_once()

      assert Enum.all?(RpcStub.log_queries(), fn {_from, to} -> to <= 98 end)
      assert Enfts.cursor(@nft).last_block == 98
      assert Enfts.get_enft("mock", 1) == nil

      RpcStub.put_head(101)
      Indexer.sync_once()

      assert Enfts.cursor(@nft).last_block == 99
      assert Enfts.get_enft("mock", 1)
    end

    test "does nothing while the head is within the confirmation depth of the deploy block" do
      put_contracts([contract("mock", @nft, 90)])
      put_blocks(90..91)
      RpcStub.put_head(91)

      log = capture_log(fn -> Indexer.sync_once() end)

      assert log == ""
      assert RpcStub.log_queries() == []
      assert Enfts.cursor(@nft) == nil
    end
  end

  describe "log chunks" do
    setup do
      previous = Application.fetch_env(:annuart, :indexer_chunk)
      Application.put_env(:annuart, :indexer_chunk, 10)

      on_exit(fn ->
        case previous do
          {:ok, v} -> Application.put_env(:annuart, :indexer_chunk, v)
          :error -> Application.delete_env(:annuart, :indexer_chunk)
        end
      end)
    end

    test "reads logs in chunks of the configured size" do
      put_contracts([contract("mock", @nft, 90)])
      put_blocks(90..115)
      RpcStub.put_head(115)

      Indexer.sync_once()

      assert RpcStub.log_queries() == [{90, 99}, {100, 109}, {110, 115}]
    end

    test "a refused log query keeps the cursor and is retried" do
      put_contracts([contract("mock", @nft, 90)])
      put_blocks(90..115)
      RpcStub.put_head(115)
      RpcStub.put_log_error(100, {:http, 429})

      log = capture_log(fn -> assert :ok = Indexer.sync_once() end)

      assert log =~ "429"
      assert Enfts.cursor(@nft).last_block == 99

      RpcStub.clear_log_errors()
      assert :ok = Indexer.sync_once()
      assert Enfts.cursor(@nft).last_block == 115
    end
  end

  describe "a chain that no longer matches the cursor" do
    # Confirmations 0 on both chains, so the cursor is at the head (block 20).
    setup do
      previous = Application.fetch_env(:annuart, :indexer_confirmations)
      Application.put_env(:annuart, :indexer_confirmations, 0)

      on_exit(fn ->
        case previous do
          {:ok, v} -> Application.put_env(:annuart, :indexer_confirmations, v)
          :error -> Application.delete_env(:annuart, :indexer_confirmations)
        end
      end)
    end

    defp indexed_on(chain_id) do
      put_contracts([contract("mock", @nft, 5)], chain_id)
      seed_basic()
      Indexer.sync_once()
      assert Enfts.get_enft("mock", 1)
      assert Enfts.cursor(@nft).last_block == 20
      Phoenix.PubSub.subscribe(Annuart.PubSub, "enfts")
    end

    defp break_chain(:head_below_cursor), do: RpcStub.put_head(8)
    defp break_chain(:cursor_block_missing), do: RpcStub.put_error(:block, :not_found)
    defp break_chain(:cursor_hash_changed), do: put_block(20, "0xother")

    for {name, change} <- [
          {"head below the cursor", :head_below_cursor},
          {"cursor block not found", :cursor_block_missing},
          {"block hash at the cursor changed", :cursor_hash_changed}
        ] do
      test "on chain 31337, #{name} wipes and rebuilds" do
        indexed_on(31_337)
        break_chain(unquote(change))
        # The new chain has none of the old history.
        RpcStub.put_logs([])
        log = capture_log(fn -> Indexer.sync_once() end)

        assert log =~ "rebuilding"
        assert Enfts.get_enft("mock", 1) == nil
      end
    end

    for {name, change} <- [
          {"head below the cursor", :head_below_cursor},
          {"cursor block not found", :cursor_block_missing}
        ] do
      test "on another chain, #{name} skips the pass and wipes nothing" do
        indexed_on(11_155_111)
        before = {Repo.all(Annuart.Enfts.Enft), Enfts.cursor(@nft)}
        break_chain(unquote(change))

        log = capture_log(fn -> assert :ok = Indexer.sync_once() end)

        assert log =~ "mock: provider is behind the cursor, skipping"
        refute log =~ "rebuilding"
        assert {Repo.all(Annuart.Enfts.Enft), Enfts.cursor(@nft)} == before
        assert drain_enft_messages() == []
      end
    end

    test "on another chain, a block hash mismatch at the cursor wipes and rebuilds" do
      indexed_on(11_155_111)
      break_chain(:cursor_hash_changed)
      put_schedule(@nft, 2, [{5, 5}])
      RpcStub.put_logs([mint_log(@nft, 2, @bob, 7, 0)])

      log = capture_log(fn -> Indexer.sync_once() end)

      assert log =~ "block hash at the cursor changed, rebuilding"
      assert Enfts.get_enft("mock", 1) == nil
      assert Enfts.get_enft("mock", 2)
      assert [{:enft_changed, "mock", 2}, :enfts_reset] = drain_enft_messages()
    end

    test "on another chain, the pass after a lagging provider catches up continues from the cursor" do
      indexed_on(11_155_111)
      break_chain(:head_below_cursor)
      capture_log(fn -> Indexer.sync_once() end)
      queried = length(RpcStub.log_queries())

      put_blocks(21..22)
      RpcStub.put_head(22)
      Indexer.sync_once()

      assert Enfts.get_enft("mock", 1)
      assert Enfts.cursor(@nft).last_block == 22
      assert [{21, 22}] = Enum.drop(RpcStub.log_queries(), queried)
    end
  end

  test "with no contracts configured the stored rows are left alone" do
    seed_basic()
    Indexer.sync_once()
    assert Enfts.get_enft("mock", 1)

    put_contracts([])
    Phoenix.PubSub.subscribe(Annuart.PubSub, "enfts")
    assert :ok = Indexer.sync_once()

    assert [%{token_id: 1}] = Repo.all(Annuart.Enfts.Enft)
    assert Enfts.cursor(@nft)
    refute :enfts_reset in drain_enft_messages()
  end
end
