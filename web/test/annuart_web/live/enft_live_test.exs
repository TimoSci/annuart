defmodule AnnuartWeb.EnftLiveTest do
  # Seeds RpcStub and application env, so not async.
  use AnnuartWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import AnnuartWeb.EnftFixtures

  @day 86_400

  setup do
    put_chain(&on_exit/1)
    stub_reads(1)
    :ok
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

  test "settled ENFT says the schedule has ended and the leftover was released", %{conn: conn} do
    mint()
    stub_reads(1, settled: true)
    {:ok, _v, html} = live(conn, ~p"/enft/mock/1")
    assert html =~ "This schedule has ended and the leftover was released to the owner."
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
      assert has_element?(view, ~s(#tx-transfer[data-confirm]))
      assert html =~ "Unclaimed balance goes with the ENFT. Claim first if you want to keep it."

      assert has_element?(
               view,
               ~s([data-secret="distribution"][phx-hook="SecretValue"][data-id="1"])
             )
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
      assert html =~ "This schedule has ended and the leftover was released to the owner."
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
end
