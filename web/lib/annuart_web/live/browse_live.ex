defmodule AnnuartWeb.BrowseLive do
  @moduledoc """
  Lists every indexed ENFT, newest first by default. Filters by donations and,
  when several contracts are configured, by contract. Needs no wallet.
  """
  use AnnuartWeb, :live_view

  alias Annuart.Chain.{Config, Reader}
  alias Annuart.{Enfts, Schedule}
  alias AnnuartWeb.{EnftComponents, Layouts}

  @filters %{"all" => nil, "on" => true, "off" => false}
  @sorts %{"newest" => :newest, "oldest" => :oldest}

  def mount(_params, _session, socket) do
    if connected?(socket), do: Phoenix.PubSub.subscribe(Annuart.PubSub, "enfts")

    {:ok,
     socket
     |> assign(
       page_title: "Browse",
       filter: "all",
       contract: nil,
       sort: "newest",
       labels: Enum.map(Config.contracts(), & &1.label),
       metas: metas_by_label()
     )
     |> load()}
  end

  def handle_event("filter", %{"donations" => filter}, socket)
      when is_map_key(@filters, filter) do
    {:noreply, socket |> assign(filter: filter) |> load()}
  end

  def handle_event("contract", %{"label" => "all"}, socket),
    do: {:noreply, socket |> assign(contract: nil) |> load()}

  def handle_event("contract", %{"label" => label}, socket) do
    if label in socket.assigns.labels,
      do: {:noreply, socket |> assign(contract: label) |> load()},
      else: {:noreply, socket}
  end

  def handle_event("sort", %{"order" => order}, socket) when is_map_key(@sorts, order) do
    {:noreply, socket |> assign(sort: order) |> load()}
  end

  def handle_info({:enft_changed, _label, _token_id}, socket), do: {:noreply, load(socket)}
  def handle_info(:enfts_reset, socket), do: {:noreply, load(socket)}

  defp load(socket) do
    %{filter: filter, contract: contract, sort: sort} = socket.assigns

    assign(socket,
      enfts:
        Enfts.list_enfts(
          top_ups: Map.fetch!(@filters, filter),
          label: contract,
          sort: Map.fetch!(@sorts, sort)
        )
    )
  end

  # Token symbol and decimals per contract label; a label is missing when its
  # token cannot be read.
  defp metas_by_label do
    for c <- Config.contracts(),
        {:ok, meta} <- [Reader.token_meta(c.token)],
        into: %{} do
      {c.label, meta}
    end
  end

  defp summary(%{schedule: nil}, _meta), do: Schedule.summary(nil, 0)
  defp summary(_enft, nil), do: "—"
  defp summary(%{schedule: schedule}, %{decimals: d}), do: Schedule.summary(schedule, d)

  defp symbol(nil), do: "—"
  defp symbol(%{symbol: symbol}), do: symbol

  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current={:browse}>
      <h1>Browse</h1>
      <p class="sub">Every ENFT on this chain. No wallet needed.</p>

      <div class="filters">
        <span class="filter-group">
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
        </span>
        <span :if={length(@labels) > 1} id="contract-filter" class="filter-group">
          <button
            :for={label <- ["all" | @labels]}
            type="button"
            id={"contract-#{label}"}
            class={@contract == if(label == "all", do: nil, else: label) && "on"}
            phx-click="contract"
            phx-value-label={label}
          >
            {if label == "all", do: "All contracts", else: label}
          </button>
        </span>
        <span class="filter-group">
          <button
            :for={{id, label} <- [{"newest", "Newest first"}, {"oldest", "Oldest first"}]}
            type="button"
            id={"sort-#{id}"}
            class={@sort == id && "on"}
            phx-click="sort"
            phx-value-order={id}
          >
            {label}
          </button>
        </span>
      </div>

      <p :if={@enfts == []}>No ENFTs yet.</p>

      <div class="rows" id="enfts">
        <.link
          :for={e <- @enfts}
          navigate={~p"/enft/#{e.label}/#{e.token_id}"}
          class="area row"
          data-activity-id={"enft:#{e.label}:#{e.token_id}"}
        >
          <EnftComponents.identity enft={e} />
          <span>{e.label}</span>
          <span>{symbol(@metas[e.label])}</span>
          <span><EnftComponents.datetime value={e.created_at} format={:date} /></span>
          <span><EnftComponents.address value={e.owner} /></span>
          <span>{summary(e, @metas[e.label])}</span>
          <span>{if e.top_ups_allowed, do: "Donations on", else: "Donations off"}</span>
        </.link>
      </div>
    </Layouts.app>
    """
  end
end
