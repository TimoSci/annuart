defmodule AnnuartWeb.EnftLiveTest do
  # Seeds RpcStub and application env, so not async.
  use AnnuartWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import AnnuartWeb.EnftFixtures
  alias Annuart.Enfts

  @day 86_400

  setup do
    put_chain(&on_exit/1)
    stub_reads(1)
    :ok
  end

  test "the heading shows the creator picture, the name and the number", %{conn: conn} do
    mint(name: "Rainy day fund")
    {:ok, view, _html} = live(conn, ~p"/enft/mock/1")

    assert has_element?(view, "h1 [data-role=enft-name]", "Rainy day fund")
    assert has_element?(view, "h1 [data-role=enft-number]", "#1")
    assert has_element?(view, ~s(h1 svg[data-role=randomart][data-creator="#{creator()}"]))
    assert page_title(view) =~ "Rainy day fund · ENFT #1"
  end

  test "an unnamed ENFT is headed ENFT and its number, still with the picture", %{conn: conn} do
    mint()
    {:ok, view, _html} = live(conn, ~p"/enft/mock/1")

    refute has_element?(view, "h1 [data-role=enft-name]")
    assert has_element?(view, "h1 [data-role=enft-identity]", "ENFT")
    # The heading's text is the name (or ENFT) and the number, nothing else.
    assert view
           |> element("h1")
           |> render()
           |> String.replace(~r/<[^>]*>/, " ")
           |> String.split() == ["ENFT", "#1"]

    assert has_element?(view, "h1 [data-role=enft-number]", "#1")
    assert has_element?(view, "h1 svg[data-role=randomart]")
    assert page_title(view) =~ "ENFT #1"
  end

  test "shows the public details", %{conn: conn} do
    enft = mint()
    transfer(enft, creator(), owner(), 5, ~U[2026-11-13 10:00:00Z])

    {:ok, _v, html} = live(conn, ~p"/enft/mock/1")

    for text <- [
          "Owner",
          "Creator",
          "Created",
          "Payouts start",
          "Payouts end",
          "Donations",
          "Last accrued",
          "Secret. Nobody can read this.",
          "Payout schedule",
          "History",
          "Created by"
        ],
        do: assert(html =~ text)

    assert html =~ "0x0000…11ce"
    assert html =~ "0x0000…c0de"
    assert html =~ ~s(data-activity-id="panel:enft:details")
    assert html =~ ~s(data-activity-id="panel:enft:schedule")
    assert html =~ ~s(data-activity-id="panel:enft:history")
    # 1 day at 1 unit/second: 86400 / day, up to 86400 payable.
    assert html =~ "86400"
  end

  test "indefinite schedule: Payouts end reads 'When the endowment runs out'", %{conn: conn} do
    mint(
      schedule: [
        %{"duration" => @day, "rate_per_sec" => 2},
        %{"duration" => indefinite(), "rate_per_sec" => 1}
      ]
    )

    {:ok, view, html} = live(conn, ~p"/enft/mock/1")
    assert html =~ "When the endowment runs out"
    assert html =~ "Indefinitely"
    assert html =~ "until empty"
    refute html =~ "leftover"
    # The indefinite period is drawn striped at a fixed 30% width.
    assert has_element?(view, ~s([data-role="bar"][data-indefinite][style*="width:30%"]))
    assert has_element?(view, ~s|[data-role="bar"]:not([data-indefinite])[style*="width:70%"]|)
  end

  test "fixed schedule notes that any leftover is paid to the owner at the end", %{conn: conn} do
    mint()
    {:ok, view, html} = live(conn, ~p"/enft/mock/1")
    assert html =~ "any leftover is paid to the owner at the end"
    assert has_element?(view, ~s([data-role="bar"][style*="width:100%"]))
    # 1_796_083_200 + 86_400
    assert html =~ "2026-12-01"
  end

  test "settled ENFT says the schedule has ended and any leftover was released", %{conn: conn} do
    mint()
    stub_reads(1, settled: true)
    {:ok, _v, html} = live(conn, ~p"/enft/mock/1")
    assert html =~ "This schedule has ended and any leftover was released to the owner."
    refute html =~ "any leftover is paid to the owner at the end"
  end

  test "hidden schedule shows Private schedule and no table", %{conn: conn} do
    mint(schedule: nil)
    {:ok, view, html} = live(conn, ~p"/enft/mock/1")
    assert html =~ "Private schedule"
    refute has_element?(view, "table.schedule")
    refute has_element?(view, ~s([data-role="bar"]))
  end

  test "history lists transfers oldest first", %{conn: conn} do
    enft = mint()
    other = "0x" <> String.duplicate("00", 18) <> "beef"
    transfer(enft, creator(), other, 5, ~U[2026-11-13 10:00:00Z])
    transfer(enft, other, owner(), 9, ~U[2026-11-20 10:00:00Z])

    {:ok, _v, html} = live(conn, ~p"/enft/mock/1")

    entries =
      Regex.scan(~r/(Created by|Transferred to) <span[^>]*>([^<]*)</, html,
        capture: :all_but_first
      )

    assert entries == [
             ["Created by", "0x0000…c0de"],
             ["Transferred to", "0x0000…beef"],
             ["Transferred to", "0x0000…11ce"]
           ]
  end

  test "unknown ENFT renders a not-found page with status 404", %{conn: conn} do
    assert_error_sent 404, fn -> get(conn, ~p"/enft/mock/99") end
    assert_error_sent 404, fn -> get(conn, ~p"/enft/nolabel/1") end
    assert_error_sent 404, fn -> get(conn, ~p"/enft/mock/abc") end
  end

  test "no secret-bearing input has a name attribute", %{conn: conn} do
    mint()
    {:ok, _v, html} = live(conn, ~p"/enft/mock/1")
    refute html =~ ~r/<input[^>]*name="amount"/
    refute html =~ ~r/<input[^>]*\bname=/
  end

  test "renders the indexed data and shows — when chain reads fail", %{conn: conn} do
    mint()
    Annuart.RpcStub.reset()

    {:ok, _v, html} = live(conn, ~p"/enft/mock/1")
    assert html =~ "0x0000…11ce"
    assert html =~ "Payout schedule"
    assert html =~ ~s(data-field="last-accrued">—)
    refute html =~ "This schedule has ended"
  end

  test "reloads when the ENFT changes", %{conn: conn} do
    enft = mint()
    {:ok, view, html} = live(conn, ~p"/enft/mock/1")
    refute html =~ "Transferred to"

    transfer(enft, creator(), owner(), 5, ~U[2026-11-13 10:00:00Z])
    Phoenix.PubSub.broadcast(Annuart.PubSub, "enfts", {:enft_changed, "mock", 1})
    assert render(view) =~ "Transferred to"
  end

  test "a start beyond the valid date range renders Far in the future", %{conn: conn} do
    mint(
      schedule_start: 18_446_744_073_709_551_000,
      schedule: [%{"duration" => indefinite(), "rate_per_sec" => 1}]
    )

    {:ok, _v, html} = live(conn, ~p"/enft/mock/1")
    assert html =~ "Far in the future"
    refute html =~ ~s(datetime="")
  end

  test "a computed end beyond the valid date range renders Far in the future", %{conn: conn} do
    mint(
      schedule_start: 1_796_083_200,
      schedule: [
        %{"duration" => 18_446_744_073_709_000_000, "rate_per_sec" => 1},
        %{"duration" => 1, "rate_per_sec" => 1}
      ]
    )

    {:ok, _v, html} = live(conn, ~p"/enft/mock/1")
    assert html =~ "Far in the future"
  end

  describe "actions" do
    defp connect_as(view, address),
      do: render_hook(view, "wallet:changed", %{"address" => address})

    @stranger "0x" <> String.duplicate("00", 18) <> "beef"

    test "owner sees Yours with claim and transfer", %{conn: conn} do
      mint()
      {:ok, view, html} = live(conn, ~p"/enft/mock/1")
      refute html =~ "As of the last accrual."

      html = connect_as(view, owner())
      assert html =~ "Yours"
      assert html =~ "As of the last accrual."
      assert has_element?(view, ~s(#tx-claim[phx-hook="TxAction"][data-action="claim"]), "Claim")
      assert has_element?(view, ~s(#tx-transfer[data-action="transfer"] input[data-arg="to"]))
      # Not data-confirm: phoenix_html would ask that itself, a second time.
      refute render(view) =~ "data-confirm"
      # The hook fills in the recipient typed into the input, in the browser.
      assert has_element?(
               view,
               ~s(#tx-transfer[data-question="Transfer ENFT #1 to {to}? Unclaimed balance goes with the ENFT. Claim first if you want to keep it."])
             )

      assert html =~ "Unclaimed balance goes with the ENFT. Claim first if you want to keep it."

      assert has_element?(
               view,
               ~s([data-secret="distribution"][phx-hook="SecretValue"][data-id="1"])
             )
    end

    test "claim and convert to ETH is offered to the owner on a wrapped-ETH contract only",
         %{conn: conn} do
      mint()
      {:ok, view, _html} = live(conn, ~p"/enft/mock/1")
      connect_as(view, owner())
      refute has_element?(view, "#tx-claim-eth")

      # The same contract, as the wrapped-ETH kind. put_chain restores the config on exit.
      chain = Application.fetch_env!(:annuart, :chain)

      Application.put_env(
        :annuart,
        :chain,
        Keyword.update!(chain, :contracts, fn [c] -> [%{c | token_kind: :wrapped}] end)
      )

      {:ok, view, _html} = live(conn, ~p"/enft/mock/1")
      refute has_element?(view, "#tx-claim-eth")

      html = connect_as(view, owner())

      assert has_element?(
               view,
               ~s(#tx-claim-eth[phx-hook="TxAction"][data-action="claimToEth"][data-token-id="1"]),
               "Claim and convert to ETH"
             )

      assert has_element?(
               view,
               ~s(#tx-claim-eth[data-question="Claim the payout and convert it to ETH? The amount converted becomes public. Your wallet will ask you to confirm four transactions."])
             )

      # The plain claim stays.
      assert has_element?(view, ~s(#tx-claim[data-action="claim"]))
      assert html =~ "The amount converted"
      assert html =~ "is public."

      connect_as(view, @stranger)
      refute has_element?(view, "#tx-claim-eth")
    end

    test "non-owner and anonymous visitors do not see Yours", %{conn: conn} do
      mint()
      {:ok, view, html} = live(conn, ~p"/enft/mock/1")
      refute html =~ "As of the last accrual."
      refute has_element?(view, "#tx-claim")

      connect_as(view, @stranger)
      refute has_element?(view, "#tx-claim")
      refute has_element?(view, "#tx-transfer")
      refute render(view) =~ "As of the last accrual."
    end

    test "donate panel hidden when donations are off", %{conn: conn} do
      mint(top_ups_allowed: false)
      {:ok, view, html} = live(conn, ~p"/enft/mock/1")
      refute html =~ "Connect a wallet to donate."
      connect_as(view, @stranger)
      refute has_element?(view, "#tx-donate")
    end

    test "donate panel hidden after a fixed schedule has ended", %{conn: conn} do
      mint(schedule_start: 1_000_000_000)
      {:ok, view, html} = live(conn, ~p"/enft/mock/1")
      refute html =~ "Connect a wallet to donate."
      connect_as(view, @stranger)
      refute has_element?(view, "#tx-donate")
    end

    test "donate panel shown on an indefinite schedule", %{conn: conn} do
      mint(
        schedule_start: 1_000_000_000,
        schedule: [%{"duration" => indefinite(), "rate_per_sec" => 1}]
      )

      {:ok, view, _html} = live(conn, ~p"/enft/mock/1")
      connect_as(view, @stranger)
      assert has_element?(view, ~s(#tx-donate[data-action="donate"] input[data-arg="amount"]))
    end

    test "anonymous visitor is told to connect a wallet to donate", %{conn: conn} do
      mint()
      {:ok, view, html} = live(conn, ~p"/enft/mock/1")
      assert html =~ "Connect a wallet to donate."
      refute has_element?(view, "#tx-donate")
      assert html =~ "Encrypted before it leaves your browser."

      connect_as(view, @stranger)
      refute render(view) =~ "Connect a wallet to donate."
      assert has_element?(view, ~s(#tx-donate[data-decimals="0"][data-symbol="TKN"]))
      # The amount is filled in by the hook, in the browser; the server never has it.
      assert has_element?(
               view,
               ~s(#tx-donate[data-question="Donate {amount} {symbol} to ENFT #1? This cannot be undone."])
             )
    end

    test "maintenance and sell panels are always shown", %{conn: conn} do
      mint()
      {:ok, view, html} = live(conn, ~p"/enft/mock/1")
      assert has_element?(view, ~s(#tx-accrue[data-action="accrue"]), "Update accrual")
      assert html =~ "Moves earned payouts into the claimable balance. Anyone may do this."
      assert has_element?(view, "button[disabled]", "Sell")
      assert html =~ "Coming soon"
    end

    test "tx:confirmed triggers a sync and refreshes last accrued", %{conn: conn} do
      mint()
      {:ok, view, html} = live(conn, ~p"/enft/mock/1")
      assert html =~ "2026-12-01"

      # 1_796_200_000 is 2026-12-02 08:26 UTC
      stub_reads(1, last_accrual_at: 1_796_200_000, settled: true)

      html =
        render_hook(view, "tx:confirmed", %{
          "action" => "accrue",
          "label" => "mock",
          "tokenId" => "1",
          "hash" => "0xabc"
        })

      assert html =~ "2026-12-02"
      assert html =~ "This schedule has ended and any leftover was released to the owner."
    end

    test "tx:confirmed payload with an amount key is ignored", %{conn: conn} do
      mint()
      {:ok, view, _html} = live(conn, ~p"/enft/mock/1")

      html =
        render_hook(view, "tx:confirmed", %{
          "action" => "donate",
          "label" => "mock",
          "tokenId" => "1",
          "hash" => "0xabc",
          "amount" => "987654321"
        })

      assert Process.alive?(view.pid)
      refute html =~ "987654321"
      refute inspect(:sys.get_state(view.pid).socket.assigns) =~ "987654321"
      # and a malformed payload is ignored too
      render_hook(view, "tx:confirmed", %{"amount" => "987654321"})
      assert Process.alive?(view.pid)
    end

    test "amount inputs carry data-arg and no name", %{conn: conn} do
      mint()
      {:ok, view, _} = live(conn, ~p"/enft/mock/1")
      html = connect_as(view, owner())
      assert html =~ ~s(data-arg="amount")
      refute html =~ ~r/<input[^>]*\bname=/
    end
  end

  describe "automatic payouts" do
    @eth 1_000_000_000_000_000_000
    @requester "0x" <> String.duplicate("00", 18) <> "f00d"

    # The configured contract, as an automatic payout one on wrapped ETH.
    # put_chain restores the config on exit.
    defp make_auto do
      chain = Application.fetch_env!(:annuart, :chain)

      Application.put_env(
        :annuart,
        :chain,
        Keyword.update!(chain, :contracts, fn [c] ->
          [%{c | token_kind: :wrapped, nft_kind: :auto}]
        end)
      )
    end

    defp settings(overrides \\ []) do
      :ok =
        Enfts.record_auto_settings(
          Map.merge(
            %{nft: nft(), token_id: 1, enabled: true, interval: 86_400, fee: div(@eth, 100)},
            Map.new(overrides)
          )
        )
    end

    defp request_id(n), do: "0x" <> String.pad_leading(Integer.to_string(n), 64, "0")

    defp requested(n, overrides \\ []) do
      :ok =
        Enfts.record_payout_requested(
          Map.merge(
            %{
              nft: nft(),
              token_id: 1,
              request_id: request_id(n),
              recipient: owner(),
              requester: @requester,
              fee_offered: 0,
              requested_at: ~U[2026-11-14 09:00:00Z],
              requested_block: 10 + n
            },
            Map.new(overrides)
          )
        )
    end

    defp paid(n, overrides) do
      :ok =
        Enfts.record_payout_paid(
          Map.merge(
            %{
              nft: nft(),
              token_id: 1,
              request_id: request_id(n),
              amount_wei: @eth,
              fee_wei: 0,
              paid_in_weth: false,
              paid_at: ~U[2026-11-14 09:01:00Z],
              paid_block: 11 + n,
              tx_hash: "0x" <> String.duplicate("0a", 32)
            },
            Map.new(overrides)
          )
        )
    end

    test "a standard contract's ENFT has no automatic payouts panel or badge", %{conn: conn} do
      mint()
      {:ok, view, html} = live(conn, ~p"/enft/mock/1")
      refute has_element?(view, "#panel-auto")
      refute has_element?(view, "#auto-payout")
      refute has_element?(view, "[data-role=auto-badge]")
      refute html =~ "Automatic"
    end

    test "the panel shows the indexed settings and None yet", %{conn: conn} do
      make_auto()
      mint()
      settings()
      {:ok, view, _html} = live(conn, ~p"/enft/mock/1")

      assert has_element?(view, "#panel-auto h2", "Automatic payouts")
      assert has_element?(view, "#auto-status", "On")
      assert has_element?(view, "#auto-interval", "At most once every 1 day")

      assert has_element?(
               view,
               "#auto-fee",
               "0.01 ETH per payout, never more than 10% of it"
             )

      assert has_element?(view, "#auto-last", "None yet")
      assert has_element?(view, ".sub [data-role=auto-badge]", "Automatic")
      # The remaining endowment is still secret.
      assert render(view) =~ "Secret. Nobody can read this."
    end

    test "switched off, without a fee: Off and No fee, and no badge", %{conn: conn} do
      make_auto()
      mint()
      settings(enabled: false, interval: 7_200, fee: 0)
      {:ok, view, _html} = live(conn, ~p"/enft/mock/1")

      assert has_element?(view, "#auto-status", "Off")
      assert has_element?(view, "#auto-interval", "At most once every 2 hours")
      assert has_element?(view, "#auto-fee", "No fee")
      refute has_element?(view, "[data-role=auto-badge]")
    end

    test "the last automatic payout comes from the store", %{conn: conn} do
      make_auto()
      mint()
      settings()
      requested(1)
      paid(1, amount_wei: div(@eth, 2), paid_at: ~U[2026-11-14 09:01:00Z])
      requested(2, requested_block: 30)

      paid(2,
        amount_wei: 1_250_000_000_000_000_000,
        paid_at: ~U[2026-11-15 09:01:00Z],
        paid_block: 31
      )

      # A later request, still pending, is not the last payout.
      requested(3, requested_block: 40)
      {:ok, view, _html} = live(conn, ~p"/enft/mock/1")

      assert has_element?(view, "#auto-last", "1.25 ETH on 2026-11-15 09:01 UTC")
    end

    test "the hook's region: data-owner is true only for the connected owner", %{conn: conn} do
      make_auto()
      mint()
      settings()
      {:ok, view, _html} = live(conn, ~p"/enft/mock/1")

      hook =
        ~s(#panel-auto #auto-payout[phx-hook="AutoPayout"][phx-update="ignore"][data-label="mock"][data-token-id="1"])

      assert has_element?(view, hook <> ~s([data-owner="false"]))
      render_hook(view, "wallet:changed", %{"address" => @stranger})
      assert has_element?(view, hook <> ~s([data-owner="false"]))
      render_hook(view, "wallet:changed", %{"address" => owner()})
      assert has_element?(view, hook <> ~s([data-owner="true"]))
      # Claim and convert to ETH stay for the owner.
      assert has_element?(view, ~s(#tx-claim[data-action="claim"]))
      assert has_element?(view, ~s(#tx-claim-eth[data-action="claimToEth"]))
    end

    test "history lists paid automatic payouts with transfers, by time", %{conn: conn} do
      make_auto()
      enft = mint()
      settings()
      transfer(enft, creator(), owner(), 5, ~U[2026-11-13 10:00:00Z])
      requested(1)

      paid(1,
        amount_wei: div(@eth, 2),
        fee_wei: div(@eth, 100),
        paid_at: ~U[2026-11-14 09:01:00Z]
      )

      # Paid in WETH, and indexed without its request: no requester is known.
      paid(2,
        amount_wei: @eth,
        paid_in_weth: true,
        paid_at: ~U[2026-11-12 20:00:00Z],
        paid_block: 3
      )

      # Pending: not in History.
      requested(3, requested_block: 40)
      {:ok, view, _html} = live(conn, ~p"/enft/mock/1")

      rows =
        view
        |> element("table.history")
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("tr")
        |> Enum.map(fn row ->
          row
          |> LazyHTML.query("td")
          |> Enum.map_join(" ", &LazyHTML.text/1)
          |> String.split()
          |> Enum.join(" ")
        end)

      assert rows == [
               "2026-11-12 Created by 0x0000…c0de",
               "2026-11-12 Automatic payout of 1 ETH (paid in WETH)",
               "2026-11-13 Transferred to 0x0000…11ce",
               "2026-11-14 Automatic payout of 0.5 ETH, fee 0.01 ETH, triggered by 0x0000…f00d"
             ]
    end
  end
end
