defmodule AnnuartWeb.BrowseLiveTest do
  # Seeds RpcStub and application env, so not async.
  use AnnuartWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import AnnuartWeb.EnftFixtures

  setup do
    put_chain(&on_exit/1)
    stub_reads(1)
    :ok
  end

  defp position(html, text) do
    {pos, _} = :binary.match(html, text)
    pos
  end

  test "lists ENFTs without a wallet, newest first", %{conn: conn} do
    mint(token_id: 1, created_at: ~U[2026-11-01 00:00:00Z])
    mint(token_id: 2, created_at: ~U[2026-11-02 00:00:00Z])

    {:ok, _v, html} = live(conn, ~p"/")
    assert html =~ "#2" and html =~ "#1"
    assert position(html, "#2") < position(html, "#1")
    assert html =~ "0x0000…11ce"
    assert html =~ "Donations on"
    assert html =~ "86400 / day for 1 day"
    assert html =~ ~s(data-activity-id="enft:mock:1")
    assert html =~ ~s(href="/enft/mock/2")
  end

  test "navigation lists the pages in order with their activity ids", %{conn: conn} do
    {:ok, _v, html} = live(conn, ~p"/")

    ids =
      Regex.scan(~r/data-activity-id="(nav:[a-z]+)"/, html) |> Enum.map(&List.last/1)

    assert ids == ["nav:browse", "nav:create", "nav:mine", "nav:market", "nav:tokens"]
    assert html =~ "soon"
    assert html =~ ~s(id="wallet")
    assert html =~ ~s(id="clear-activity")
    assert html =~ "Clear my activity history"
  end

  test "filters by donations on/off", %{conn: conn} do
    mint(token_id: 1, top_ups_allowed: true)
    mint(token_id: 2, top_ups_allowed: false)

    {:ok, view, html} = live(conn, ~p"/")
    assert html =~ "#1" and html =~ "#2"

    html = view |> element("#filter-off") |> render_click()
    assert html =~ "#2"
    refute html =~ "#1"

    html = view |> element("#filter-on") |> render_click()
    assert html =~ "#1"
    refute html =~ "#2"

    html = view |> element("#filter-all") |> render_click()
    assert html =~ "#1" and html =~ "#2"
  end

  test "hidden schedule shows Private schedule", %{conn: conn} do
    mint(token_id: 1, schedule: nil)
    {:ok, _v, html} = live(conn, ~p"/")
    assert html =~ "Private schedule"
  end

  test "a new mint appears without reload", %{conn: conn} do
    mint(token_id: 1)
    {:ok, view, html} = live(conn, ~p"/")
    refute html =~ "enft:mock:3"

    mint(token_id: 3)
    Phoenix.PubSub.broadcast(Annuart.PubSub, "enfts", {:enft_changed, "mock", 3})
    assert render(view) =~ ~s(data-activity-id="enft:mock:3")
  end

  test "reloads on enfts_reset", %{conn: conn} do
    mint(token_id: 1)
    {:ok, view, _} = live(conn, ~p"/")
    Annuart.Enfts.reset_contract(nft())
    Phoenix.PubSub.broadcast(Annuart.PubSub, "enfts", :enfts_reset)
    html = render(view)
    refute html =~ "#1"
    assert html =~ "No ENFTs yet."
  end

  test "empty state", %{conn: conn} do
    {:ok, _v, html} = live(conn, ~p"/")
    assert html =~ "No ENFTs yet."
  end
end
