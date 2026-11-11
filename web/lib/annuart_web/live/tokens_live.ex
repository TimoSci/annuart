defmodule AnnuartWeb.TokensLive do
  @moduledoc """
  A card per configured token: the connected wallet's confidential balance,
  its authorisation of the ENFT contract, and, depending on the token, a
  faucet or wrap and unwrap controls. Balances and authorisation are read in
  the browser by the `Tokens` hook (`assets/js/hooks/tokens.js`), so the server
  only renders the frame. Each card is one `phx-update="ignore"` region; the
  hook fills it and draws the actions it adds.

  Amount inputs carry `data-arg` and no `name`.
  """
  use AnnuartWeb, :live_view

  alias Annuart.Chain.{Config, Reader}
  alias AnnuartWeb.{Layouts, TxComponents}

  def mount(_params, _session, socket) do
    {:ok, assign(socket, page_title: "Tokens")}
  end

  # Nothing to do on "tx:confirmed": the hook re-reads the balances itself.
  def handle_event("tx:confirmed", _params, socket), do: {:noreply, socket}

  # Label, kind, and the symbol and decimals read from the token; `nil` when the
  # chain cannot be read, and the hook then refuses to parse amounts.
  defp cards do
    for %Config.Contract{label: label, token: token, token_kind: kind} <- Config.contracts() do
      case Reader.token_meta(token) do
        {:ok, %{symbol: symbol, decimals: decimals}} ->
          %{label: label, kind: kind, symbol: symbol, decimals: decimals}

        _ ->
          %{label: label, kind: kind, symbol: nil, decimals: nil}
      end
    end
  end

  def render(assigns) do
    assigns = assign(assigns, :cards, if(assigns.address, do: cards(), else: []))

    ~H"""
    <Layouts.app flash={@flash} current={:tokens}>
      <h1>Tokens</h1>
      <p :if={@address == nil}>Connect a wallet to see your tokens.</p>
      <p :if={@address != nil and @cards == []}>No ENFT contracts are configured.</p>

      <div
        :for={c <- @cards}
        id={"token-#{c.label}"}
        class="area panel token"
        phx-hook="Tokens"
        phx-update="ignore"
        data-activity-id={"panel:tokens:#{c.label}"}
        data-label={c.label}
        data-kind={c.kind}
        data-symbol={c.symbol}
        data-decimals={c.decimals}
      >
        <h2>{c.label}<span :if={c.symbol}> ({c.symbol})</span></h2>

        <div class="field">
          <label>Balance</label>
          <span
            id={"balance-#{c.label}"}
            phx-hook="SecretValue"
            data-secret="balance"
            data-label={c.label}
            data-symbol={c.symbol}
            data-decimals={c.decimals}
          >
          </span>
        </div>

        <div class="field">
          <label>ENFT contract</label>
          <span data-role="authorisation"></span>
          <TxComponents.action
            id={"tx-authorise-#{c.label}"}
            action="authorise"
            label="Authorise"
            contract_label={c.label}
          />
        </div>

        <div :if={c.kind == :mock} class="field">
          <TxComponents.action
            id={"tx-faucet-#{c.label}"}
            action="faucet"
            label="Get test tokens"
            contract_label={c.label}
            decimals={c.decimals}
            symbol={c.symbol}
          >
            <input type="hidden" data-arg="amount" value="1000" />
          </TxComponents.action>
        </div>

        <div :if={c.kind == :wrapped}>
          <div class="field">
            <label>ETH in your wallet</label>
            <span data-role="eth-balance"></span>
          </div>
          <TxComponents.action
            id={"tx-wrap-#{c.label}"}
            action="wrap"
            label="Wrap"
            contract_label={c.label}
            decimals={c.decimals}
            symbol={c.symbol}
          >
            <input
              type="text"
              inputmode="decimal"
              data-arg="wei"
              placeholder="ETH to wrap"
              autocomplete="off"
            />
          </TxComponents.action>
          <TxComponents.action
            id={"tx-unwrap-#{c.label}"}
            action="unwrap"
            label="Unwrap"
            contract_label={c.label}
            decimals={c.decimals}
            symbol={c.symbol}
          >
            <input
              type="text"
              inputmode="decimal"
              data-arg="amount"
              placeholder={"#{c.symbol} to unwrap"}
              autocomplete="off"
            />
          </TxComponents.action>
          <p class="note">Wrapped and unwrapped amounts are public.</p>
          <p class="note">Amounts below 0.000000001 ETH cannot be wrapped and stay in your wallet.</p>
          <div data-role="unwraps" hidden></div>
          <div data-role="weth" hidden></div>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
