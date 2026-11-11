defmodule AnnuartWeb.TokensLiveTest do
  # Seeds RpcStub and application env, so not async.
  use AnnuartWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import AnnuartWeb.EnftFixtures

  alias Annuart.Chain.{Abi, Config}
  alias Annuart.RpcStub

  @alice "0xAb5801a7D398351b8bE11C439e05C5B3259aeC9B"

  setup do
    put_chain(&on_exit/1)
    stub_reads(1)
    :ok
  end

  defp connected(conn) do
    {:ok, view, _} = live(conn, ~p"/tokens")
    html = render_hook(view, "wallet:changed", %{"address" => @alice})
    {view, html}
  end

  # Replaces the configured contracts with `kinds`, one per kind, sharing the stubbed token.
  defp put_kinds(kinds) do
    {:ok, chain} = Application.fetch_env(:annuart, :chain)

    contracts =
      for kind <- kinds do
        %Config.Contract{
          label: Atom.to_string(kind),
          nft: nft(),
          token: token(),
          token_kind: kind,
          underlying: if(kind == :wrapped, do: "0x" <> String.duplicate("c3", 20)),
          deploy_block: 0
        }
      end

    Application.put_env(:annuart, :chain, Keyword.put(chain, :contracts, contracts))
  end

  test "prompts to connect without an address", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/tokens")
    assert html =~ "Connect a wallet to see your tokens."
    refute html =~ "Get test tokens"
  end

  test "mock token card offers test tokens and no wrap controls", %{conn: conn} do
    {_view, html} = connected(conn)
    refute html =~ "Connect a wallet to see your tokens."
    assert html =~ "Get test tokens"
    assert html =~ ~s(data-action="faucet")
    assert html =~ ~s(data-secret="balance")
    assert html =~ ~s(data-action="authorise")
    assert html =~ ~s(data-role="authorisation")
    refute html =~ ~s(data-action="wrap")
    refute html =~ ~s(data-action="unwrap")
    refute html =~ "Wrapped and unwrapped amounts are public."
  end

  test "wrapped token card offers wrap and unwrap and says amounts are public", %{conn: conn} do
    put_kinds([:wrapped])
    {_view, html} = connected(conn)
    assert html =~ ~s(data-action="wrap")
    assert html =~ ~s(data-action="unwrap")
    assert html =~ ~s(data-arg="wei")
    assert html =~ ~s(data-arg="amount")
    assert html =~ "Wrapped and unwrapped amounts are public."
    assert html =~ "Amounts below 0.000000001 ETH cannot be wrapped and stay in your wallet."
    assert html =~ ~s(data-role="eth-balance")
    refute html =~ "Get test tokens"
  end

  test "plain token card offers neither", %{conn: conn} do
    put_kinds([:plain])
    {_view, html} = connected(conn)
    assert html =~ ~s(data-secret="balance")
    assert html =~ ~s(data-action="authorise")
    refute html =~ "Get test tokens"
    refute html =~ ~s(data-action="wrap")
    refute html =~ ~s(data-action="unwrap")
  end

  test "symbol and decimals come from the chain", %{conn: conn} do
    RpcStub.put_call(token(), Abi.encode_call(:decimals, []), {:ok, word(6)})
    {_view, html} = connected(conn)
    assert html =~ ~s(data-symbol="TKN")
    assert html =~ ~s(data-decimals="6")
    assert html =~ "TKN"
  end

  test "the card carries no amounts and the faucet input has no name", %{conn: conn} do
    {_view, html} = connected(conn)
    refute html =~ ~r/<input[^>]*\bname=/
  end
end
