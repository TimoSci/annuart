defmodule AnnuartWeb.MarketLive do
  @moduledoc "Placeholder for buying and selling ENFTs."
  use AnnuartWeb, :live_view

  alias AnnuartWeb.Layouts

  def mount(_params, _session, socket), do: {:ok, assign(socket, page_title: "Market")}

  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current={:market}>
      <h1>Market</h1>
      <div class="area panel" data-activity-id="panel:market">
        <h2>Market</h2>
        <p>Buying and selling is coming soon.</p>
      </div>
    </Layouts.app>
    """
  end
end
