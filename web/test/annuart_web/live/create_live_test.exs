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

  @hash "0x" <> String.duplicate("ab12", 16)

  defp confirmed(view, token_id, extra \\ %{}) do
    render_hook(
      view,
      "tx:confirmed",
      Map.merge(
        %{
          "action" => "createEnft",
          "label" => "mock",
          "tokenId" => token_id,
          "hash" => @hash
        },
        extra
      )
    )
  end

  test "tx:confirmed for createEnft navigates at once when the ENFT is indexed", %{conn: conn} do
    mint(token_id: 3)
    {view, _} = connected(conn)
    confirmed(view, "3")
    assert_redirect(view, ~p"/enft/mock/3")
  end

  test "tx:confirmed for an ENFT not yet indexed waits, then navigates on its broadcast", %{
    conn: conn
  } do
    {view, _} = connected(conn)
    html = confirmed(view, "3")
    assert html =~ "Created. Waiting for it to appear…"
    refute_redirected(view)

    # Another ENFT appearing does not end the wait.
    Phoenix.PubSub.broadcast(Annuart.PubSub, "enfts", {:enft_changed, "mock", 9})
    _ = render(view)
    refute_redirected(view)

    mint(token_id: 3)
    Phoenix.PubSub.broadcast(Annuart.PubSub, "enfts", {:enft_changed, "mock", 3})
    assert_redirect(view, ~p"/enft/mock/3")
  end

  test "after the timeout it stops waiting and shows the hash and a link", %{conn: conn} do
    Application.put_env(:annuart, :create_wait_ms, 20)
    on_exit(fn -> Application.delete_env(:annuart, :create_wait_ms) end)
    {view, _} = connected(conn)
    confirmed(view, "3")
    Process.sleep(80)
    html = render(view)
    assert html =~ "Your ENFT was created. It is taking longer than usual to appear."
    assert html =~ @hash
    assert html =~ ~s(href="/enft/mock/3")
    refute html =~ "Waiting for it to appear"
    refute_redirected(view)
  end

  test "tx:confirmed ignores unusable token ids without crashing", %{conn: conn} do
    {view, _} = connected(conn)

    for bad <- [%{"a" => 1}, [3], -3, "-3", "abc", "3.5", nil] do
      confirmed(view, bad)
    end

    assert Process.alive?(view.pid)
    refute render(view) =~ "Waiting for it to appear"
    refute_redirected(view)
  end

  test "an integer token id is accepted", %{conn: conn} do
    mint(token_id: 4)
    {view, _} = connected(conn)
    confirmed(view, 4)
    assert_redirect(view, ~p"/enft/mock/4")
  end

  test "tx:confirmed with an unknown label or another action stays on the page", %{conn: conn} do
    {view, _} = connected(conn)

    for params <- [
          %{"action" => "createEnft", "label" => "nope", "tokenId" => "3", "hash" => "0x"},
          %{"action" => "donate", "label" => "mock", "tokenId" => "3", "hash" => "0x"},
          %{"amount" => "987654321"}
        ] do
      render_hook(view, "tx:confirmed", params)
    end

    assert Process.alive?(view.pid)
    refute_redirected(view)
  end

  test "tx:confirmed is ignored unless the hash is 0x and 64 hex digits", %{conn: conn} do
    mint(token_id: 3)
    {view, _} = connected(conn)

    for bad <- [
          "0xabc123",
          "0x" <> String.duplicate("a", 63),
          "0x" <> String.duplicate("a", 65),
          "0x" <> String.duplicate("g", 64),
          String.duplicate("a", 66),
          "0x" <> String.duplicate("a", 64) <> "\n",
          "<script>alert(1)</script>",
          123
        ] do
      confirmed(view, "3", %{"hash" => bad})
    end

    assert Process.alive?(view.pid)
    refute_redirected(view)
    refute render(view) =~ "Waiting for it to appear"

    confirmed(view, "3", %{"hash" => "0x" <> String.duplicate("AbCd", 16)})
    assert_redirect(view, ~p"/enft/mock/3")
  end

  test "tx:confirmed ignores any other key", %{conn: conn} do
    mint(token_id: 3)
    {view, _} = connected(conn)
    confirmed(view, "3", %{"amount" => "987654321"})
    assert_redirect(view, ~p"/enft/mock/3")
  end
end
