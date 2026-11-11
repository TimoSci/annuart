defmodule AnnuartWeb.WalletHookTest do
  # Seeds RpcStub and application env, so not async.
  use AnnuartWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import AnnuartWeb.EnftFixtures

  @alice "0xAb5801a7D398351b8bE11C439e05C5B3259aeC9B"

  setup do
    put_chain(&on_exit/1)
    mint()
    stub_reads(1)
    :ok
  end

  # /enft is not MyEnftsLive: the hook must work on every page, not just /mine.
  test "wallet:changed assigns a valid address, lowercased", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/enft/mock/1")
    assert :sys.get_state(view.pid).socket.assigns.address == nil

    render_hook(view, "wallet:changed", %{"address" => @alice})
    assert :sys.get_state(view.pid).socket.assigns.address == String.downcase(@alice)
  end

  test "wallet:changed with null clears the address", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/enft/mock/1")
    render_hook(view, "wallet:changed", %{"address" => @alice})
    render_hook(view, "wallet:changed", %{"address" => nil})
    assert :sys.get_state(view.pid).socket.assigns.address == nil
  end

  test "wallet:changed with a malformed value is ignored", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/enft/mock/1")
    render_hook(view, "wallet:changed", %{"address" => @alice})
    good = String.downcase(@alice)

    for bad <- [
          "0x123",
          "<script>",
          42,
          "",
          good <> "00",
          "0x" <> String.duplicate("g", 40),
          %{"a" => 1},
          [good]
        ] do
      render_hook(view, "wallet:changed", %{"address" => bad})
      assert :sys.get_state(view.pid).socket.assigns.address == good
    end

    render_hook(view, "wallet:changed", %{})
    assert :sys.get_state(view.pid).socket.assigns.address == good
  end

  test "the wallet slot carries the hook and survives patches", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/enft/mock/1")
    assert html =~ ~s(id="wallet")
    assert html =~ ~s(phx-hook="Wallet")
    assert html =~ ~s(phx-update="ignore")
  end
end
