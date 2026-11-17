defmodule AnnuartWeb.TransactionsLiveTest do
  # Seeds RpcStub and application env, so not async.
  use AnnuartWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import AnnuartWeb.EnftFixtures

  alias Annuart.Txs

  @alice "0xAb5801a7D398351b8bE11C439e05C5B3259aeC9B"
  @bob "0xb0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0"

  defp record(n, overrides) do
    :ok =
      Txs.record(
        Map.merge(
          %{
            nft: nft(),
            label: "mock",
            tx_hash: "0x" <> String.duplicate(Integer.to_string(n), 64),
            block_number: n,
            tx_index: 0,
            at: ~U[2026-11-13 10:00:00Z],
            from: String.downcase(@alice),
            to: nft(),
            kind: "claim",
            token_id: 1,
            amount: nil,
            amount_unit: nil,
            parties: [String.downcase(@alice)]
          },
          Map.new(overrides)
        )
      )
  end

  setup do
    put_chain(&on_exit/1)
    Annuart.RpcStub.reset()
    stub_reads(1)
    record(1, %{kind: "faucet", to: token(), token_id: nil, amount: 1_500, amount_unit: "token"})
    record(2, %{kind: "create"})

    record(3, %{
      kind: "payout_finalise",
      from: @bob,
      amount: 2_000_000_000_000_000,
      amount_unit: "wei"
    })

    record(4, %{kind: "claim", from: @bob, parties: [@bob]})
    :ok
  end

  test "prompts to connect when no address", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/transactions")
    assert html =~ "Connect a wallet to see its transactions."
    refute html =~ ~s(id="transactions")
  end

  test "lists the connected address's transactions with type, amount and visibility", %{
    conn: conn
  } do
    {:ok, view, _} = live(conn, ~p"/transactions")
    render_hook(view, "wallet:changed", %{"address" => @alice})

    rows = view |> element("#transactions tbody") |> render()
    # Newest first; bob's own claim is not alice's.
    assert Regex.scan(~r/data-kind="(\w+)"/, rows, capture: :all_but_first) ==
             [["payout_finalise"], ["create"], ["faucet"]]

    paid = view |> element(~s(tr[data-kind="payout_finalise"])) |> render()
    assert paid =~ "Pay automatic payout" and paid =~ "0.002 ETH" and paid =~ "Public"
    assert paid =~ ~s(href="/enft/mock/1")
    refute paid =~ "(you)"

    created = view |> element(~s(tr[data-kind="create"])) |> render()
    assert created =~ "Create ENFT" and created =~ "Private"
    assert created =~ "(you)"

    faucet = view |> element(~s(tr[data-kind="faucet"])) |> render()
    assert faucet =~ "Get test tokens" and faucet =~ "1500 TKN" and faucet =~ "Public"
    refute faucet =~ "/enft/"
  end

  test "a private-rate create reads as such and as private", %{conn: conn} do
    record(5, %{kind: "create_private"})
    {:ok, view, _} = live(conn, ~p"/transactions")
    render_hook(view, "wallet:changed", %{"address" => @alice})

    row = view |> element(~s(tr[data-kind="create_private"])) |> render()
    assert row =~ "Create private-rate ENFT" and row =~ "Private"
  end

  test "the sender of a private transaction gets a reveal control and a security warning", %{
    conn: conn
  } do
    {:ok, view, _} = live(conn, ~p"/transactions")
    refute has_element?(view, "#reveal-warning")
    render_hook(view, "wallet:changed", %{"address" => @alice})

    hash = "0x" <> String.duplicate("2", 64)

    assert has_element?(
             view,
             ~s(tr[data-kind="create"] #reveal-#{hash}[phx-hook="SecretValue"][data-secret="tx"]) <>
               ~s([data-tx="#{hash}"][data-label="mock"][data-decimals="0"][data-symbol="TKN"])
           )

    assert view |> element("#reveal-warning") |> render() =~ "computer you trust"
    # Public rows have nothing to reveal.
    refute has_element?(view, ~s(tr[data-kind="faucet"] [phx-hook="SecretValue"]))
  end

  test "private is explained as encrypted, not secret, and an unwrap request is public", %{
    conn: conn
  } do
    record(8, %{
      kind: "unwrap_request",
      from: @bob,
      to: token(),
      token_id: nil,
      parties: [@bob, String.downcase(@alice)]
    })

    {:ok, view, _} = live(conn, ~p"/transactions")
    render_hook(view, "wallet:changed", %{"address" => @alice})

    assert render(view) =~
             "Private means the amount is encrypted on chain, not that it is secret: the amount of a claim can often be worked out from the public schedule."

    unwrap = view |> element(~s(tr[data-kind="unwrap_request"])) |> render()
    assert unwrap =~ "Public" and unwrap =~ "Not shown"
    refute unwrap =~ "Private"
    refute unwrap =~ "Hidden"
  end

  test "a private transaction someone else sent has no reveal control", %{conn: conn} do
    record(6, %{kind: "donate", from: @bob, parties: [@bob, String.downcase(@alice)]})
    {:ok, view, _} = live(conn, ~p"/transactions")
    render_hook(view, "wallet:changed", %{"address" => @alice})

    donated = view |> element(~s(tr[data-kind="donate"])) |> render()
    assert donated =~ "Hidden"
    refute donated =~ "SecretValue"

    # The recipient of a plain token transfer is one of its two ends.
    record(7, %{
      kind: "token_transfer",
      from: @bob,
      to: token(),
      token_id: nil,
      parties: [@bob, String.downcase(@alice)]
    })

    Phoenix.PubSub.broadcast(Annuart.PubSub, "txs", :txs_changed)
    assert has_element?(view, ~s(tr[data-kind="token_transfer"] [phx-hook="SecretValue"]))
  end

  test "an address without transactions is told so, and a new one appears when indexed", %{
    conn: conn
  } do
    carol = "0x" <> String.duplicate("ce", 20)
    {:ok, view, _} = live(conn, ~p"/transactions")

    assert render_hook(view, "wallet:changed", %{"address" => carol}) =~
             "No transactions with this app"

    record(5, %{
      kind: "wrap",
      from: carol,
      token_id: nil,
      amount: 10,
      amount_unit: "wei",
      parties: [carol]
    })

    Phoenix.PubSub.broadcast(Annuart.PubSub, "txs", :txs_changed)
    assert render(view) =~ "Wrap ETH"
  end

  test "the navigation links to the page", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/")
    assert html =~ ~s(href="/transactions")
  end
end
