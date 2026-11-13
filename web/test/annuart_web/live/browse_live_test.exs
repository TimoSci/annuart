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

  test "every row shows the creator picture and the number, and the name when there is one",
       %{conn: conn} do
    mint(token_id: 1, name: "Rainy day fund")
    mint(token_id: 2)

    {:ok, view, _html} = live(conn, ~p"/")

    for id <- [1, 2] do
      row = ~s(a[data-activity-id="enft:mock:#{id}"] [data-role=enft-identity])
      assert has_element?(view, ~s(#{row} svg[data-role=randomart][data-creator="#{creator()}"]))
      assert has_element?(view, "#{row} [data-role=enft-number]", "##{id}")
    end

    named = ~s(a[data-activity-id="enft:mock:1"] [data-role=enft-name])
    assert has_element?(view, named, "Rainy day fund")
    refute has_element?(view, ~s(a[data-activity-id="enft:mock:2"] [data-role=enft-name]))
  end

  test "two ENFTs with the same name from different creators have different pictures",
       %{conn: conn} do
    other = "0x" <> String.duplicate("00", 18) <> "beef"
    mint(token_id: 1, name: "Same")
    mint(token_id: 2, name: "Same", creator: other)

    {:ok, view, _html} = live(conn, ~p"/")

    art = fn id ->
      view
      |> element(~s(a[data-activity-id="enft:mock:#{id}"] svg[data-role=randomart]))
      |> render()
      |> String.replace(~r/(aria-label|data-creator)="[^"]*"/, "")
    end

    assert art.(1) != art.(2)
  end

  test "the page does not carry the server RPC URL off the local chain", %{conn: conn} do
    previous = Application.fetch_env!(:annuart, :chain)
    on_exit(fn -> Application.put_env(:annuart, :chain, previous) end)

    Application.put_env(:annuart, :chain,
      chain_id: 11_155_111,
      rpc_url: "https://rpc.example/v3/SECRET",
      contracts: []
    )

    html = html_response(get(conn, ~p"/"), 200)
    refute html =~ "SECRET"
    refute html =~ "rpc.example"
    {:ok, _v, live_html} = live(conn, ~p"/")
    refute live_html =~ "SECRET"
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

  # Each nav item is a live navigation, so the wallet session, revealed values
  # and FHE permits held in the page survive moving between pages.
  test "every navigation item navigates live", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    for {id, path} <- [
          {"nav:browse", "/"},
          {"nav:create", "/create"},
          {"nav:mine", "/mine"},
          {"nav:market", "/market"},
          {"nav:tokens", "/tokens"}
        ] do
      assert has_element?(
               view,
               ~s([data-activity-id="#{id}"][href="#{path}"][data-phx-link="redirect"])
             ),
             "#{id} is not a live navigation link to #{path}"
    end
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

  @other_nft "0x" <> String.duplicate("a9", 20)

  # A second contract, "other", using the same token.
  defp add_other_contract do
    chain = Application.get_env(:annuart, :chain)
    [first] = chain[:contracts]
    other = %{first | label: "other", nft: @other_nft}
    Application.put_env(:annuart, :chain, Keyword.put(chain, :contracts, [first, other]))
  end

  defp row_text(view, label, id),
    do: view |> element(~s(#enfts [data-activity-id="enft:#{label}:#{id}"])) |> render()

  test "each row shows the contract label, the token symbol and the created date", %{conn: conn} do
    mint(token_id: 1, created_at: ~U[2026-11-12 14:03:00Z])
    {:ok, view, _html} = live(conn, ~p"/")
    row = row_text(view, "mock", 1)
    assert row =~ ~r/>\s*mock\s*</
    assert row =~ "TKN"
    assert row =~ ~s(datetime="2026-11-12T14:03:00Z")
    assert row =~ "2026-11-12"
  end

  test "with one contract there is no contract filter", %{conn: conn} do
    mint(token_id: 1)
    {:ok, view, _html} = live(conn, ~p"/")
    refute has_element?(view, "#contract-filter")
    assert has_element?(view, "#sort-newest")
  end

  test "with several contracts a contract filter narrows the list", %{conn: conn} do
    add_other_contract()
    mint(token_id: 1)
    mint(label: "other", nft: @other_nft, token_id: 7)

    {:ok, view, _html} = live(conn, ~p"/")
    assert has_element?(view, "#contract-filter")
    assert has_element?(view, ~s(#enfts [data-activity-id="enft:mock:1"]))
    assert has_element?(view, ~s(#enfts [data-activity-id="enft:other:7"]))

    view |> element("#contract-other") |> render_click()
    refute has_element?(view, ~s(#enfts [data-activity-id="enft:mock:1"]))
    assert has_element?(view, ~s(#enfts [data-activity-id="enft:other:7"]))
    assert has_element?(view, "#contract-other.on")

    # Combined with the donations filter.
    view |> element("#filter-off") |> render_click()
    refute has_element?(view, ~s(#enfts [data-activity-id="enft:other:7"]))

    view |> element("#filter-all") |> render_click()
    view |> element("#contract-all") |> render_click()
    assert has_element?(view, ~s(#enfts [data-activity-id="enft:mock:1"]))
    assert has_element?(view, ~s(#enfts [data-activity-id="enft:other:7"]))
  end

  test "an unknown contract filter is ignored", %{conn: conn} do
    add_other_contract()
    mint(token_id: 1)
    {:ok, view, _html} = live(conn, ~p"/")
    render_click(view, "contract", %{"label" => "nope"})
    assert has_element?(view, ~s(#enfts [data-activity-id="enft:mock:1"]))
  end

  test "sorts newest first or oldest first", %{conn: conn} do
    mint(token_id: 1, created_at: ~U[2026-11-01 00:00:00Z])
    mint(token_id: 2, created_at: ~U[2026-11-02 00:00:00Z])
    {:ok, view, html} = live(conn, ~p"/")
    assert position(html, "enft:mock:2") < position(html, "enft:mock:1")
    assert has_element?(view, "#sort-newest.on")

    html = view |> element("#sort-oldest") |> render_click()
    assert position(html, "enft:mock:1") < position(html, "enft:mock:2")
    assert has_element?(view, "#sort-oldest.on")

    html = view |> element("#sort-newest") |> render_click()
    assert position(html, "enft:mock:2") < position(html, "enft:mock:1")
  end

  test "empty state", %{conn: conn} do
    {:ok, _v, html} = live(conn, ~p"/")
    assert html =~ "No ENFTs yet."
  end

  test "ENFTs with out-of-range timestamps still list", %{conn: conn} do
    mint(
      token_id: 1,
      schedule_start: 18_446_744_073_709_551_000,
      schedule: [%{"duration" => indefinite(), "rate_per_sec" => 1}]
    )

    mint(
      token_id: 2,
      schedule: [%{"duration" => 18_446_744_073_709_000_000, "rate_per_sec" => 1}]
    )

    {:ok, _v, html} = live(conn, ~p"/")
    assert html =~ ~s(data-activity-id="enft:mock:1")
    assert html =~ ~s(data-activity-id="enft:mock:2")
  end

  test "marks only ENFTs with automatic payouts on", %{conn: conn} do
    mint(token_id: 1)
    mint(token_id: 2)
    mint(token_id: 3)

    :ok =
      Annuart.Enfts.record_auto_settings(%{
        nft: nft(),
        token_id: 2,
        enabled: true,
        interval: 3_600,
        fee: 0
      })

    :ok =
      Annuart.Enfts.record_auto_settings(%{
        nft: nft(),
        token_id: 3,
        enabled: false,
        interval: 3_600,
        fee: 0
      })

    {:ok, view, _html} = live(conn, ~p"/")
    row = &~s(a[data-activity-id="enft:mock:#{&1}"] [data-role=auto-badge])
    assert has_element?(view, row.(2), "Automatic")
    refute has_element?(view, row.(1))
    refute has_element?(view, row.(3))
  end
end
