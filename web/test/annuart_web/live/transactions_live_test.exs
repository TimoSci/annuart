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
    assert created =~ "Create ENFT" and created =~ "Hidden" and created =~ "Private"
    assert created =~ "(you)"

    faucet = view |> element(~s(tr[data-kind="faucet"])) |> render()
    assert faucet =~ "Get test tokens" and faucet =~ "1500 TKN" and faucet =~ "Public"
    refute faucet =~ "/enft/"
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
