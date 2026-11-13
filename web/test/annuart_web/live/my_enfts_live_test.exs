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
    # The reveal slot itself is left alone by LiveView patches.
    assert has_element?(
             view,
             ~s(#secret-distribution-mock-3[phx-hook="SecretValue"][phx-update="ignore"])
           )
  end

  test "each row shows the creator picture, the name when there is one, and the number",
       %{conn: conn} do
    mint(token_id: 4, owner: String.downcase(@alice), name: "Rainy day fund")
    {:ok, view, _} = live(conn, ~p"/mine")
    render_hook(view, "wallet:changed", %{"address" => @alice})

    assert has_element?(view, "#mine-mock-4 [data-role=enft-name]", "Rainy day fund")
    assert has_element?(view, "#mine-mock-4 [data-role=enft-number]", "#4")

    assert has_element?(
             view,
             ~s(#mine-mock-4 svg[data-role=randomart][data-creator="#{creator()}"])
           )

    refute has_element?(view, "#mine-mock-1 [data-role=enft-name]")
    assert has_element?(view, "#mine-mock-1 [data-role=enft-number]", "#1")
    assert has_element?(view, "#mine-mock-1 svg[data-role=randomart]")
  end

  test "each row has a Claim action for that ENFT", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/mine")
    render_hook(view, "wallet:changed", %{"address" => @alice})

    for id <- [1, 3] do
      claim = ~s(#mine-mock-#{id} #claim-mock-#{id})
      assert has_element?(view, claim <> ~s([phx-hook="TxAction"][phx-update="ignore"]))
      assert has_element?(view, claim <> ~s([data-action="claim"][data-label="mock"]))
      assert has_element?(view, claim <> ~s([data-token-id="#{id}"]))
      assert has_element?(view, claim <> " button[data-role=run]", "Claim")
    end

    refute has_element?(view, "#claim-mock-2")
  end

  test "rows on a wrapped-ETH contract also offer Claim and convert to ETH", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/mine")
    render_hook(view, "wallet:changed", %{"address" => @alice})
    refute has_element?(view, "#claim-eth-mock-1")

    # The same contract, as the wrapped-ETH kind. put_chain restores the config on exit.
    chain = Application.fetch_env!(:annuart, :chain)

    Application.put_env(
      :annuart,
      :chain,
      Keyword.update!(chain, :contracts, fn [c] -> [%{c | token_kind: :wrapped}] end)
    )

    {:ok, view, _} = live(conn, ~p"/mine")
    render_hook(view, "wallet:changed", %{"address" => @alice})

    for id <- [1, 3] do
      both = ~s(#mine-mock-#{id} #claim-eth-mock-#{id})

      assert has_element?(
               view,
               both <> ~s([phx-hook="TxAction"][data-action="claimToEth"][data-token-id="#{id}"])
             )

      assert has_element?(view, both <> ~s([data-question*="becomes public"]))
      assert has_element?(view, both <> " button[data-role=run]", "Claim and convert to ETH")
      assert has_element?(view, ~s(#mine-mock-#{id} #claim-mock-#{id}))
    end

    refute has_element?(view, "#claim-eth-mock-2")
  end

  test "a confirmed claim is accepted and the list stays", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/mine")
    render_hook(view, "wallet:changed", %{"address" => @alice})

    html =
      render_hook(view, "tx:confirmed", %{
        "action" => "claim",
        "label" => "mock",
        "tokenId" => "1",
        "hash" => "0x" <> String.duplicate("ab", 32)
      })

    assert html =~ ~s(href="/enft/mock/1")
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
