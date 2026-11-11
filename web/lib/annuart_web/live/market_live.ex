defmodule AnnuartWeb.MarketLive do
  @moduledoc "Placeholder for buying and selling ENFTs."
  use AnnuartWeb, :live_view

  alias AnnuartWeb.Layouts

  def mount(_params, _session, socket), do: {:ok, assign(socket, page_title: "Market")}

  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current={:market}>
      <h1>Market</h1>
      <p class="sub">Buying and selling is coming soon.</p>
    </Layouts.app>
    """
  end
end
