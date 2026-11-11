defmodule AnnuartWeb.MyEnftsLiveTest do
  # Seeds RpcStub and application env, so not async.
  use AnnuartWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import AnnuartWeb.EnftFixtures

  @alice "0xAb5801a7D398351b8bE11C439e05C5B3259aeC9B"
  @bob "0xB0B0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0B0"

  setup do
    put_chain(&on_exit/1)
    mint(token_id: 1, owner: String.downcase(@alice))
    mint(token_id: 2, owner: String.downcase(@bob))
    mint(token_id: 3, owner: String.downcase(@alice), created_at: ~U[2026-11-13 14:03:00Z])
    :ok
  end

  test "prompts to connect when no address", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/mine")
    assert html =~ "Connect a wallet to see your ENFTs."
    refute html =~ ~s(href="/enft/mock/1")
  end

  test "lists only ENFTs owned by the connected address", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/mine")
    html = render_hook(view, "wallet:changed", %{"address" => @alice})

    refute html =~ "Connect a wallet to see your ENFTs."
    assert html =~ ~s(href="/enft/mock/1")
    assert html =~ ~s(href="/enft/mock/3")
    refute html =~ ~s(href="/enft/mock/2")
    # Newest first.
    assert :binary.match(html, "/enft/mock/3") < :binary.match(html, "/enft/mock/1")
    # The reveal slot Task 10 wires up.
    assert html =~ ~s(data-secret="distribution")
    assert html =~ ~s(data-label="mock")
    assert html =~ ~s(data-id="3")
    assert html =~ ~s(phx-update="ignore")
  end

  test "updates when the address changes", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/mine")
    html = render_hook(view, "wallet:changed", %{"address" => @alice})
    assert html =~ ~s(href="/enft/mock/1")

    html = render_hook(view, "wallet:changed", %{"address" => @bob})
    assert html =~ ~s(href="/enft/mock/2")
    refute html =~ ~s(href="/enft/mock/1")

    html = render_hook(view, "wallet:changed", %{"address" => nil})
    assert html =~ "Connect a wallet to see your ENFTs."
    refute html =~ ~s(href="/enft/mock/2")
  end

  test "says so when the address owns nothing", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/mine")
    html = render_hook(view, "wallet:changed", %{"address" => "0x" <> String.duplicate("11", 20)})
    assert html =~ "You do not own any ENFTs yet."
  end

  test "reflects a transfer announced while connected", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/mine")
    render_hook(view, "wallet:changed", %{"address" => @alice})

    Annuart.Enfts.record_transfer(%{
      enft_id: Annuart.Enfts.get_enft("mock", 1).id,
      from: String.downcase(@alice),
      to: String.downcase(@bob),
      block_number: 9,
      log_index: 0,
      tx_hash: "0x" <> String.duplicate("9", 64),
      at: ~U[2026-11-14 00:00:00Z]
    })

    Phoenix.PubSub.broadcast(Annuart.PubSub, "enfts", {:enft_changed, "mock", 1})
    html = render(view)
    refute html =~ ~s(href="/enft/mock/1")
  end
end
