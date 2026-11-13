defmodule AnnuartWeb.MyEnftsLive do
  @moduledoc """
  The ENFTs owned by the connected wallet. The address comes from the browser
  (see `AnnuartWeb.WalletHook`) and only selects which public rows to list.
  """
  use AnnuartWeb, :live_view

  alias Annuart.Chain.{Config, Reader}
  alias Annuart.{Enfts, Indexer}
  alias AnnuartWeb.{EnftComponents, Layouts, TxComponents}

  def mount(_params, _session, socket) do
    if connected?(socket), do: Phoenix.PubSub.subscribe(Annuart.PubSub, "enfts")
    {:ok, assign(socket, page_title: "My ENFTs", refresh: 0)}
  end

  # A claim was confirmed in the browser. Nothing in the event is used: the
  # indexer is asked to look, and the hook re-reads what is secret itself.
  def handle_event("tx:confirmed", _params, socket) do
    Indexer.sync_now()
    {:noreply, socket}
  end

  # Ownership may have changed: bump a counter so the list below is re-read.
  def handle_info({:enft_changed, _label, _token_id}, socket), do: {:noreply, bump(socket)}
  def handle_info(:enfts_reset, socket), do: {:noreply, bump(socket)}

  defp bump(socket), do: assign(socket, :refresh, socket.assigns.refresh + 1)

  # `refresh` is only here so the template re-reads the list when it changes.
  defp owned(nil, _refresh), do: nil
  defp owned(address, _refresh), do: Enfts.list_owned(address)

  # Decimals and symbol of each token the listed ENFTs use, for the reveal
  # control to format with. One read per distinct contract.
  defp metas(nil), do: %{}

  defp metas(enfts) do
    for label <- enfts |> Enum.map(& &1.label) |> Enum.uniq(),
        %Config.Contract{token: token} <- [Config.contract(label)],
        {:ok, meta} <- [Reader.token_meta(token)],
        into: %{},
        do: {label, meta}
  end

  defp meta(metas, label), do: Map.get(metas, label)

  # Only a payout in wrapped ETH can be converted to ETH.
  defp wrapped?(label), do: match?(%Config.Contract{token_kind: :wrapped}, Config.contract(label))

  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current={:mine}>
      <h1>My ENFTs</h1>
      <% enfts = owned(@address, @refresh) %>
      <% metas = metas(enfts) %>
      <p :if={enfts == nil}>Connect a wallet to see your ENFTs.</p>
      <p :if={enfts == []}>You do not own any ENFTs yet.</p>

      <div class="rows" id="my-enfts">
        <div
          :for={e <- enfts || []}
          class="area row"
          id={"mine-#{e.label}-#{e.token_id}"}
          data-activity-id={"enft:#{e.label}:#{e.token_id}"}
        >
          <.link navigate={~p"/enft/#{e.label}/#{e.token_id}"} class="enft-link">
            <EnftComponents.identity enft={e} />
            <span>· {e.label}</span>
          </.link>
          <span>
            Created <EnftComponents.datetime value={e.created_at} format={:date} />
          </span>
          <span>{if e.top_ups_allowed, do: "Donations on", else: "Donations off"}</span>
          <span
            id={"secret-distribution-#{e.label}-#{e.token_id}"}
            phx-hook="SecretValue"
            data-secret="distribution"
            data-label={e.label}
            data-id={e.token_id}
            data-decimals={meta(metas, e.label) && meta(metas, e.label).decimals}
            data-symbol={meta(metas, e.label) && meta(metas, e.label).symbol}
            phx-update="ignore"
          >
          </span>
          <TxComponents.action
            id={"claim-#{e.label}-#{e.token_id}"}
            action="claim"
            label="Claim"
            contract_label={e.label}
            token_id={e.token_id}
          />
          <TxComponents.claim_to_eth
            :if={wrapped?(e.label)}
            id={"claim-eth-#{e.label}-#{e.token_id}"}
            contract_label={e.label}
            token_id={e.token_id}
          />
        </div>
      </div>
    </Layouts.app>
    """
  end
end
