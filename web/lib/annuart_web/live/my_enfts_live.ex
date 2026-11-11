defmodule AnnuartWeb.MyEnftsLive do
  @moduledoc """
  The ENFTs owned by the connected wallet. The address comes from the browser
  (see `AnnuartWeb.WalletHook`) and only selects which public rows to list.
  """
  use AnnuartWeb, :live_view

  alias Annuart.Enfts
  alias AnnuartWeb.{EnftComponents, Layouts}

  def mount(_params, _session, socket) do
    if connected?(socket), do: Phoenix.PubSub.subscribe(Annuart.PubSub, "enfts")
    {:ok, assign(socket, page_title: "My ENFTs", refresh: 0)}
  end

  # Ownership may have changed: bump a counter so the list below is re-read.
  def handle_info({:enft_changed, _label, _token_id}, socket), do: {:noreply, bump(socket)}
  def handle_info(:enfts_reset, socket), do: {:noreply, bump(socket)}

  defp bump(socket), do: assign(socket, :refresh, socket.assigns.refresh + 1)

  # `refresh` is only here so the template re-reads the list when it changes.
  defp owned(nil, _refresh), do: nil
  defp owned(address, _refresh), do: Enfts.list_owned(address)

  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current={:mine}>
      <h1>My ENFTs</h1>
      <% enfts = owned(@address, @refresh) %>
      <p :if={enfts == nil}>Connect a wallet to see your ENFTs.</p>
      <p :if={enfts == []}>You do not own any ENFTs yet.</p>

      <div class="rows" id="my-enfts">
        <div
          :for={e <- enfts || []}
          class="area row"
          id={"mine-#{e.label}-#{e.token_id}"}
          data-activity-id={"enft:#{e.label}:#{e.token_id}"}
        >
          <.link navigate={~p"/enft/#{e.label}/#{e.token_id}"}>#{e.token_id} · {e.label}</.link>
          <span>
            Created <EnftComponents.datetime value={e.created_at} format={:date} />
          </span>
          <span>{if e.top_ups_allowed, do: "Donations on", else: "Donations off"}</span>
          <span
            id={"secret-distribution-#{e.label}-#{e.token_id}"}
            data-secret="distribution"
            data-label={e.label}
            data-id={e.token_id}
            phx-update="ignore"
          >
          </span>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
