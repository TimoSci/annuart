defmodule AnnuartWeb.NotFoundError do
  @moduledoc "Raised when an ENFT page is requested for an ENFT that is not indexed."
  defexception message: "ENFT not found", plug_status: 404
end

defmodule AnnuartWeb.EnftLive do
  @moduledoc """
  One ENFT: its public details, payout schedule and history. Needs no wallet.

  Indexed data comes from the store; `last_accrual_at`, `settled` and the token's
  metadata are read live and are `nil` when the chain cannot be read.
  """
  use AnnuartWeb, :live_view

  alias Annuart.Chain.{Config, Reader}
  alias Annuart.{Enfts, Schedule}
  alias AnnuartWeb.{EnftComponents, Layouts}

  @zero_address "0x0000000000000000000000000000000000000000"

  def mount(%{"label" => label, "id" => id}, _session, socket) do
    with {token_id, ""} <- Integer.parse(id),
         %Config.Contract{} = contract <- Config.contract(label),
         %Enfts.Enft{} <- Enfts.get_enft(label, token_id) do
      if connected?(socket), do: Phoenix.PubSub.subscribe(Annuart.PubSub, "enfts")

      {:ok,
       socket
       |> assign(
         page_title: "ENFT ##{token_id}",
         contract: contract,
         label: label,
         token_id: token_id
       )
       |> load()}
    else
      _ -> raise AnnuartWeb.NotFoundError
    end
  end

  def handle_info({:enft_changed, label, token_id}, socket)
      when label == socket.assigns.label and token_id == socket.assigns.token_id,
      do: {:noreply, load(socket)}

  def handle_info({:enft_changed, _label, _token_id}, socket), do: {:noreply, socket}
  def handle_info(:enfts_reset, socket), do: {:noreply, load(socket)}

  defp load(socket) do
    %{contract: contract, label: label, token_id: token_id} = socket.assigns

    case Enfts.get_enft(label, token_id) do
      nil ->
        raise AnnuartWeb.NotFoundError

      enft ->
        assign(socket,
          enft: enft,
          periods: periods(enft),
          transfers: Enum.reject(Enfts.history(enft), &(&1.from == @zero_address)),
          token_meta: ok_or_nil(Reader.token_meta(contract.token)),
          last_accrual_at: ok_or_nil(Reader.last_accrual_at(contract.nft, token_id)),
          settled: ok_or_nil(Reader.settled(contract.nft, token_id))
        )
    end
  end

  defp periods(%{schedule: nil}), do: nil

  defp periods(%{schedule: schedule, schedule_start: start}),
    do: Schedule.periods(schedule, start)

  defp ok_or_nil({:ok, value}), do: value
  defp ok_or_nil(_), do: nil

  defp payouts_end(%{schedule: nil}), do: {:text, "Private schedule"}

  defp payouts_end(%{schedule: schedule, schedule_start: start}) do
    case Schedule.ends_at(schedule, start) do
      :never -> {:text, "When the endowment runs out"}
      at -> {:time, at}
    end
  end

  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <h1>ENFT #{@token_id}</h1>
      <p class="sub">
        {@label} · created <EnftComponents.datetime value={@enft.created_at} format={:date} />
      </p>

      <div class="grid">
        <div class="col">
          <div class="area panel" data-activity-id="panel:enft:details">
            <h2>Details</h2>
            <div class="kv">
              <span class="k">Owner</span>
              <span><EnftComponents.address value={@enft.owner} /></span>
              <span class="k">Creator</span>
              <span><EnftComponents.address value={@enft.creator} /></span>
              <span class="k">Created</span>
              <span><EnftComponents.datetime value={@enft.created_at} /></span>
              <span class="k">Payouts start</span>
              <span><EnftComponents.datetime value={@enft.schedule_start} /></span>
              <span class="k">Payouts end</span>
              <span>
                <%= case payouts_end(@enft) do %>
                  <% {:text, text} -> %>
                    {text}
                  <% {:time, at} -> %>
                    <EnftComponents.datetime value={at} />
                <% end %>
              </span>
              <span class="k">Donations</span>
              <span>{if @enft.top_ups_allowed, do: "On", else: "Off"}</span>
              <span class="k">Remaining</span>
              <span>Secret. Nobody can read this.</span>
              <span class="k">Last accrued</span>
              <span>
                <EnftComponents.datetime data-field="last-accrued" value={@last_accrual_at} />
              </span>
            </div>
          </div>

          <div class="area panel" data-activity-id="panel:enft:schedule">
            <h2>Payout schedule</h2>
            <%= if @periods do %>
              <EnftComponents.schedule_chart periods={@periods} />
              <EnftComponents.schedule_table
                periods={@periods}
                decimals={@token_meta && @token_meta.decimals}
                symbol={@token_meta && @token_meta.symbol}
              />
            <% else %>
              <p>Private schedule</p>
            <% end %>
            <p :if={@settled == true} class="note">
              This schedule has ended and the leftover was released to the owner.
            </p>
            <p
              :if={(@settled != true and @periods) && not Schedule.indefinite?(@enft.schedule)}
              class="note"
            >
              If the endowment outlasts the schedule, any leftover is paid to the owner at the end.
            </p>
          </div>

          <div class="area panel" data-activity-id="panel:enft:history">
            <h2>History</h2>
            <table class="history">
              <tbody>
                <tr>
                  <td><EnftComponents.datetime value={@enft.created_at} format={:date} /></td>
                  <td>Created by <EnftComponents.address value={@enft.creator} /></td>
                </tr>
                <tr :for={t <- @transfers}>
                  <td><EnftComponents.datetime value={t.at} format={:date} /></td>
                  <td>Transferred to <EnftComponents.address value={t.to} /></td>
                </tr>
              </tbody>
            </table>
          </div>
        </div>
        <div class="col" id="enft-side"></div>
      </div>
    </Layouts.app>
    """
  end
end
