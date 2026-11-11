defmodule AnnuartWeb.DevBundleTest do
  # Not async: it mutates application env.
  use AnnuartWeb.ConnCase, async: false

  setup do
    previous_wallet = Application.fetch_env(:annuart, :dev_wallet)
    previous_chain = Application.fetch_env(:annuart, :chain)

    on_exit(fn ->
      restore(:dev_wallet, previous_wallet)
      restore(:chain, previous_chain)
    end)
  end

  defp restore(key, {:ok, value}), do: Application.put_env(:annuart, key, value)
  defp restore(key, :error), do: Application.delete_env(:annuart, key)

  test "root layout references dev.js only when dev_wallet is on", %{conn: conn} do
    Application.put_env(:annuart, :dev_wallet, true)
    html = html_response(get(conn, ~p"/"), 200)
    assert html =~ "/assets/dev.js"
    # the dev bundle must load before the app bundle
    {dev_at, _} = :binary.match(html, "/assets/dev.js")
    {app_at, _} = :binary.match(html, "/assets/app.js")
    assert dev_at < app_at

    Application.put_env(:annuart, :dev_wallet, false)
    refute html_response(get(conn, ~p"/"), 200) =~ "/assets/dev.js"
  end

  test "chain meta tag carries chain id, rpc url and contracts", %{conn: conn} do
    Application.put_env(:annuart, :chain,
      chain_id: 31337,
      rpc_url: "http://127.0.0.1:8545",
      contracts: [
        %Annuart.Chain.Config.Contract{
          label: "mock",
          nft: "0xaa",
          token: "0xbb",
          token_kind: :mock,
          underlying: nil,
          deploy_block: 4
        },
        %Annuart.Chain.Config.Contract{
          label: "wrapped",
          nft: "0xcc",
          token: "0xdd",
          token_kind: :wrapped,
          underlying: "0xee",
          deploy_block: 11
        }
      ]
    )

    html = html_response(get(conn, ~p"/"), 200)

    [content] =
      html
      |> LazyHTML.from_document()
      |> LazyHTML.query(~s(meta[name="annuart-chain"]))
      |> LazyHTML.attribute("content")

    meta = Jason.decode!(content)
    assert meta["chainId"] == 31337
    assert meta["rpcUrl"] == "http://127.0.0.1:8545"
    assert Enum.map(meta["contracts"], & &1["label"]) == ["mock", "wrapped"]

    assert %{
             "nft" => "0xcc",
             "token" => "0xdd",
             "tokenKind" => "wrapped",
             "underlying" => "0xee",
             "deployBlock" => 11
           } = Enum.at(meta["contracts"], 1)
  end

  test "with no loadable deployment the meta tag claims no chain", %{conn: conn} do
    Application.put_env(:annuart, :chain,
      chain_id: 0,
      rpc_url: "http://127.0.0.1:8545",
      contracts: []
    )

    [content] =
      get(conn, ~p"/")
      |> html_response(200)
      |> LazyHTML.from_document()
      |> LazyHTML.query(~s(meta[name="annuart-chain"]))
      |> LazyHTML.attribute("content")

    assert %{"chainId" => 0, "contracts" => []} = Jason.decode!(content)
  end
end
