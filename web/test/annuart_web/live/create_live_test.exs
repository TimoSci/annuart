defmodule AnnuartWeb.CreateLiveTest do
  # Seeds RpcStub and application env, so not async.
  use AnnuartWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import AnnuartWeb.EnftFixtures

  @alice "0xAb5801a7D398351b8bE11C439e05C5B3259aeC9B"

  setup do
    put_chain(&on_exit/1)
    stub_reads(1)
    :ok
  end

  defp connected(conn) do
    {:ok, view, _} = live(conn, ~p"/create")
    html = render_hook(view, "wallet:changed", %{"address" => @alice})
    {view, html}
  end

  test "prompts to connect without an address", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/create")
    assert html =~ "Connect a wallet to create an ENFT."
    refute html =~ ~s(id="create-form")
  end

  test "renders the three sections and the units note when connected", %{conn: conn} do
    {_view, html} = connected(conn)
    refute html =~ "Connect a wallet to create an ENFT."

    for text <- [
          "1. Endowment",
          "2. Payout schedule",
          "3. Options",
          "Encrypted in your browser. Nobody but you will ever know this number.",
          "A month is 30 days and a year is 365 days.",
          "+ Add period",
          "Payouts start",
          "Allow donations",
          "Cannot be changed later.",
          "Recipient",
          "Create ENFT"
        ],
        do: assert(html =~ text)

    assert html =~ ~s(phx-hook="CreateForm")
    assert html =~ ~s(data-secret="balance")
    # One token configured: shown, not selectable.
    refute html =~ "<select data-role=\"token\""
    assert html =~ ~s(data-symbol="TKN")
  end

  test "offers a token selector when several contracts are configured", %{conn: conn} do
    [first] = Application.get_env(:annuart, :chain)[:contracts]
    other = %{first | label: "other"}
    chain = Application.get_env(:annuart, :chain)
    Application.put_env(:annuart, :chain, Keyword.put(chain, :contracts, [first, other]))

    {_view, html} = connected(conn)
    assert html =~ ~s(<select data-role="token")
    assert html =~ "mock (TKN)"
    assert html =~ "other (TKN)"
  end

  test "no amount input has a name and the form has no phx-change or phx-submit", %{conn: conn} do
    {_view, html} = connected(conn)
    assert html =~ ~s(data-role="amount")
    refute html =~ ~r/<input[^>]*\bname=/
    refute html =~ "phx-change"
    refute html =~ "phx-submit"
    assert html =~ ~s(phx-update="ignore")
  end

  test "tx:confirmed for createEnft navigates to the new ENFT", %{conn: conn} do
    {view, _} = connected(conn)

    render_hook(view, "tx:confirmed", %{
      "action" => "createEnft",
      "label" => "mock",
      "tokenId" => "3",
      "hash" => "0xabc"
    })

    assert_redirect(view, ~p"/enft/mock/3")
  end

  test "tx:confirmed with an unknown label or malformed token id stays on the page", %{conn: conn} do
    {view, _} = connected(conn)

    for params <- [
          %{"action" => "createEnft", "label" => "nope", "tokenId" => "3", "hash" => "0x"},
          %{"action" => "createEnft", "label" => "mock", "tokenId" => "3; drop", "hash" => "0x"},
          %{"action" => "donate", "label" => "mock", "tokenId" => "3", "hash" => "0x"},
          %{"amount" => "987654321"}
        ] do
      render_hook(view, "tx:confirmed", params)
    end

    assert Process.alive?(view.pid)
    refute_redirected(view)
  end

  test "tx:confirmed ignores any other key", %{conn: conn} do
    {view, _} = connected(conn)

    render_hook(view, "tx:confirmed", %{
      "action" => "createEnft",
      "label" => "mock",
      "tokenId" => "3",
      "hash" => "0xabc",
      "amount" => "987654321"
    })

    # The redirect is to exactly the ENFT; the extra key goes nowhere.
    assert_redirect(view, ~p"/enft/mock/3")
  end
end
