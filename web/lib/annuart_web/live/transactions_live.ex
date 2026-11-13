defmodule AnnuartWeb.TransactionsLive do
  @moduledoc """
  The transactions that involve the connected wallet's address: what each one
  did, and whether its amount is encrypted. The address comes from the browser
  (see `AnnuartWeb.WalletHook`) and only selects which public rows to list;
  every value shown is public chain data, and an encrypted amount is never known
  to the server.
  """
  use AnnuartWeb, :live_view

  alias Annuart.Chain.{Config, Reader}
  alias Annuart.{Indexer, Schedule, Txs}
  alias AnnuartWeb.{EnftComponents, Layouts}

  @limit 300
  @eth_decimals 18

  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Annuart.PubSub, "txs")
      Phoenix.PubSub.subscribe(Annuart.PubSub, "enfts")
    end

    {:ok, assign(socket, page_title: "Transactions", refresh: 0)}
  end

  def handle_event("tx:confirmed", _params, socket) do
    Indexer.sync_now()
    {:noreply, socket}
  end

  def handle_info(:txs_changed, socket), do: {:noreply, bump(socket)}
  def handle_info(:enfts_reset, socket), do: {:noreply, bump(socket)}
  def handle_info({:enft_changed, _label, _token_id}, socket), do: {:noreply, socket}

  defp bump(socket), do: assign(socket, :refresh, socket.assigns.refresh + 1)

  # `refresh` is only here so the template re-reads the list when it changes.
  defp txs(nil, _refresh), do: nil
  defp txs(address, _refresh), do: Txs.list_for(address, @limit)

  # Decimals and symbol of each token an amount is counted in. One read per contract.
  defp metas(nil), do: %{}

  defp metas(txs) do
    for label <-
          txs |> Enum.filter(&(&1.amount_unit == "token")) |> Enum.map(& &1.label) |> Enum.uniq(),
        %Config.Contract{token: token} <- [Config.contract(label)],
        {:ok, meta} <- [Reader.token_meta(token)],
        into: %{},
        do: {label, meta}
  end

  @types %{
    "create" => "Create ENFT",
    "create_auto" => "Create automatic ENFT",
    "donate" => "Donate to ENFT",
    "claim" => "Claim payout",
    "accrue" => "Update accrual",
    "transfer" => "Transfer ENFT",
    "auto_settings" => "Change automatic payout settings",
    "payout_request" => "Request automatic payout",
    "payout_finalise" => "Pay automatic payout",
    "authorise" => "Authorise contract",
    "faucet" => "Get test tokens",
    "wrap" => "Wrap ETH",
    "unwrap_request" => "Request unwrap",
    "unwrap_finalise" => "Finalise unwrap",
    "token_transfer" => "Send confidential tokens"
  }
  defp type(kind), do: Map.get(@types, kind, "Other")

  defp amount(%{amount: nil} = tx, _metas),
    do: if(Txs.private?(tx.kind), do: "Hidden", else: "")

  defp amount(%{amount: amount, amount_unit: "wei"}, _metas),
    do: Schedule.format_amount(amount, @eth_decimals) <> " ETH"

  defp amount(%{amount: amount, label: label}, metas) do
    case metas do
      %{^label => %{decimals: decimals, symbol: symbol}} ->
        Schedule.format_amount(amount, decimals) <> " " <> symbol

      _ ->
        ""
    end
  end

  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current={:transactions}>
      <h1>Transactions</h1>
      <% txs = txs(@address, @refresh) %>
      <% metas = metas(txs) %>
      <p :if={txs == nil}>Connect a wallet to see its transactions.</p>
      <p :if={txs == []}>No transactions with this app's contracts yet.</p>

      <div :if={txs not in [nil, []]} class="area panel">
        <p class="sub">
          Transactions sent to this app's ENFT contracts and their tokens that involve your
          address. Private means the amount is encrypted on chain; the transaction itself is
          always public. Conversions between ETH and WETH are not listed.
        </p>
        <table class="history" id="transactions">
          <thead>
            <tr>
              <th>When</th>
              <th>Type</th>
              <th>ENFT</th>
              <th>Sent by</th>
              <th>Amount</th>
              <th>Visibility</th>
              <th>Transaction</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={t <- txs} id={"tx-#{t.tx_hash}"} data-kind={t.kind}>
              <td><EnftComponents.datetime value={t.at} /></td>
              <td>{type(t.kind)}</td>
              <td>
                <.link :if={t.token_id} navigate={~p"/enft/#{t.label}/#{t.token_id}"}>
                  {t.label} #{t.token_id}
                </.link>
                <span :if={!t.token_id}>{t.label}</span>
              </td>
              <td><EnftComponents.address value={t.from} you={t.from == @address} /></td>
              <td>{amount(t, metas)}</td>
              <td>{if Txs.private?(t.kind), do: "Private", else: "Public"}</td>
              <td><span class="addr" title={t.tx_hash}>{EnftComponents.short(t.tx_hash)}</span></td>
            </tr>
          </tbody>
        </table>
        <p :if={length(txs) == limit()} class="sub">Showing the latest {limit()} transactions.</p>
      </div>
    </Layouts.app>
    """
  end

  defp limit, do: @limit
end
