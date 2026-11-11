defmodule AnnuartWeb.BrowseLive do
  @moduledoc "Lists every indexed ENFT, newest first. Needs no wallet."
  use AnnuartWeb, :live_view

  alias Annuart.Chain.{Config, Reader}
  alias Annuart.{Enfts, Schedule}
  alias AnnuartWeb.{EnftComponents, Layouts}

  @filters %{"all" => nil, "on" => true, "off" => false}

  def mount(_params, _session, socket) do
    if connected?(socket), do: Phoenix.PubSub.subscribe(Annuart.PubSub, "enfts")

    {:ok,
     socket
     |> assign(page_title: "Browse", filter: "all", decimals: decimals_by_label())
     |> load()}
  end

  def handle_event("filter", %{"donations" => filter}, socket)
      when is_map_key(@filters, filter) do
    {:noreply, socket |> assign(filter: filter) |> load()}
  end

  def handle_info({:enft_changed, _label, _token_id}, socket), do: {:noreply, load(socket)}
  def handle_info(:enfts_reset, socket), do: {:noreply, load(socket)}

  defp load(socket) do
    assign(socket, enfts: Enfts.list_enfts(top_ups: Map.fetch!(@filters, socket.assigns.filter)))
  end

  # Token decimals per contract label; a label is missing when its token cannot be read.
  defp decimals_by_label do
    for c <- Config.contracts(),
        {:ok, %{decimals: d}} <- [Reader.token_meta(c.token)],
        into: %{} do
      {c.label, d}
    end
  end

  defp summary(%{schedule: nil}, _decimals), do: Schedule.summary(nil, 0)
  defp summary(_enft, nil), do: "—"
  defp summary(%{schedule: schedule}, decimals), do: Schedule.summary(schedule, decimals)

  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current={:browse}>
      <h1>Browse</h1>
      <p class="sub">Every ENFT on this chain. No wallet needed.</p>

      <div class="filters">
        <button
          :for={{id, label} <- [{"all", "All"}, {"on", "Donations on"}, {"off", "Donations off"}]}
          type="button"
          id={"filter-#{id}"}
          class={@filter == id && "on"}
          phx-click="filter"
          phx-value-donations={id}
        >
          {label}
        </button>
      </div>

      <p :if={@enfts == []}>No ENFTs yet.</p>

      <div class="rows" id="enfts">
        <.link
          :for={e <- @enfts}
          navigate={~p"/enft/#{e.label}/#{e.token_id}"}
          class="area row"
          data-activity-id={"enft:#{e.label}:#{e.token_id}"}
        >
          <span>#{e.token_id}</span>
          <span><EnftComponents.address value={e.owner} /></span>
          <span>{summary(e, @decimals[e.label])}</span>
          <span>{if e.top_ups_allowed, do: "Donations on", else: "Donations off"}</span>
        </.link>
      </div>
    </Layouts.app>
    """
  end
end
