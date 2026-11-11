defmodule AnnuartWeb.MarketLiveTest do
  use AnnuartWeb.ConnCase, async: true
  import Phoenix.LiveViewTest

  test "says buying and selling is coming soon and has no form or button", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/market")
    assert html =~ "Buying and selling is coming soon."
    refute has_element?(view, "main form")
    refute has_element?(view, "main button")
    refute has_element?(view, "main input")
  end
end
