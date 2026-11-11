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
    refute html =~ "will be paid"
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
end
