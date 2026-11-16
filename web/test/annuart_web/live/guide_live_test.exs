defmodule AnnuartWeb.GuideLiveTest do
  use AnnuartWeb.ConnCase, async: true
  import Phoenix.LiveViewTest

  @sections [
    {"what-is-an-enft", "What an ENFT is"},
    {"getting-started", "Getting started"},
    {"tokens", "Getting and converting tokens"},
    {"creating", "Creating an ENFT"},
    {"owning", "Owning an ENFT"},
    {"donating", "Donating"},
    {"automatic-payouts", "Automatic payouts"},
    {"privacy", "What is private and what is public"},
    {"keeping-the-total-private", "Keeping the endowment total private"}
  ]

  test "the guide has a contents list that links to every section, in order", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/guide")
    assert has_element?(view, "main h1", "User guide")

    assert Regex.scan(~r/<a href="#([a-z-]+)" data-role="contents-link"/, html,
             capture: :all_but_first
           ) ==
             Enum.map(@sections, fn {id, _} -> [id] end)

    for {id, title} <- @sections do
      assert has_element?(view, ~s(#guide-contents a[href="##{id}"]), title)
      assert has_element?(view, ~s(main section##{id} h2), title)
    end
  end

  test "every section takes part in the activity brightness", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/guide")

    for {id, _} <- @sections,
        do: assert(has_element?(view, ~s(section##{id}[data-activity-id="panel:guide:#{id}"])))
  end

  test "the guide is reading only and needs no wallet", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/guide")
    refute has_element?(view, "main form")
    refute has_element?(view, "main button")
    refute has_element?(view, "main input")
    refute html =~ "Connect a wallet to"
    assert has_element?(view, ~s(.nav-item.current[data-activity-id="nav:guide"]), "Guide")
  end

  test "the section on keeping the total private covers the creator, the owner and the limits",
       %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/guide")
    section = view |> element("section#keeping-the-total-private") |> render()

    for text <- [
          "only on an ENFT without automatic payouts",
          "If you create the ENFT",
          "Do not switch on automatic payouts.",
          "Do not wrap exactly the endowment amount.",
          "Never disclose the amount",
          "If you own the ENFT",
          "Do not unwrap claims as they arrive.",
          "Only use Reveal on a computer you trust",
          "What cannot be hidden",
          "The schedule and the time of every accrual and claim are public"
        ],
        do: assert(section =~ text, "missing: #{text}")
  end

  test "the guide links to the pages it describes", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/guide")

    for path <- ["/tokens", "/create", "/mine", "/transactions"],
        do: assert(has_element?(view, ~s(main a[href="#{path}"][data-phx-link="redirect"])))
  end
end
