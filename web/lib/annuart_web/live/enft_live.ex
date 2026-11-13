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
  alias Annuart.Indexer
  alias AnnuartWeb.{EnftComponents, Layouts, TxComponents}

  @zero_address "0x0000000000000000000000000000000000000000"

  def mount(%{"label" => label, "id" => id}, _session, socket) do
    with {token_id, ""} <- Integer.parse(id),
         %Config.Contract{} = contract <- Config.contract(label),
         %Enfts.Enft{} = enft <- Enfts.get_enft(label, token_id) do
      if connected?(socket), do: Phoenix.PubSub.subscribe(Annuart.PubSub, "enfts")

      {:ok,
       socket
       |> assign(
         page_title: if(enft.name, do: "#{enft.name} · ", else: "") <> "ENFT ##{token_id}",
         contract: contract,
         label: label,
         token_id: token_id
       )
       |> load()}
    else
      _ -> raise AnnuartWeb.NotFoundError
    end
  end

  # A transaction was confirmed in the browser. Only these four public values
  # are read from the event; anything else in it is ignored, never stored.
  def handle_event(
        "tx:confirmed",
        %{"action" => _, "label" => _, "tokenId" => _, "hash" => _},
        socket
      ) do
    Indexer.sync_now()
    %{contract: contract, token_id: token_id} = socket.assigns

    {:noreply,
     assign(socket,
       last_accrual_at: ok_or_nil(Reader.last_accrual_at(contract.nft, token_id)),
       settled: ok_or_nil(Reader.settled(contract.nft, token_id))
     )}
  end

  def handle_event("tx:confirmed", _params, socket), do: {:noreply, socket}

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

  # Donations are accepted while the contract allows them and the schedule has
  # not ended. A hidden schedule cannot be checked, so the contract decides.
  defp donations_open?(%{top_ups_allowed: false}, _settled), do: false
  defp donations_open?(_enft, true), do: false
  defp donations_open?(%{schedule: nil}, _settled), do: true

  defp donations_open?(%{schedule: schedule, schedule_start: start}, _settled) do
    case Schedule.ends_at(schedule, start) do
      :never -> true
      at -> at > System.os_time(:second)
    end
  end

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
      <h1><EnftComponents.identity enft={@enft} unnamed="ENFT" size={:large} /></h1>
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
              <span class="creator" title={"Creator #{@enft.creator}"}>
                <EnftComponents.randomart address={@enft.creator} />
                <EnftComponents.address value={@enft.creator} />
              </span>
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
              This schedule has ended and any leftover was released to the owner.
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
        <div class="col" id="enft-side">
          <div
            :if={@address != nil and @address == @enft.owner}
            class="area panel"
            id="panel-yours"
            data-activity-id="panel:enft:yours"
          >
            <h2>Yours</h2>
            <div class="kv">
              <span class="k">Claimable</span>
              <span
                id="secret-claimable"
                phx-hook="SecretValue"
                phx-update="ignore"
                data-secret="distribution"
                data-label={@label}
                data-id={@token_id}
                data-decimals={@token_meta && @token_meta.decimals}
                data-symbol={@token_meta && @token_meta.symbol}
              >
              </span>
            </div>
            <p class="note">As of the last accrual.</p>
            <TxComponents.action
              id="tx-claim"
              action="claim"
              label="Claim"
              contract_label={@label}
              token_id={@token_id}
            />
            <div :if={@contract.token_kind == :wrapped} id="claim-to-eth">
              <TxComponents.claim_to_eth
                id="tx-claim-eth"
                contract_label={@label}
                token_id={@token_id}
              />
              <p class="note">
                Claims the payout and pays it into your wallet as plain ETH. The amount converted
                is public. If it stops part-way, the payout is safe: finish it under Tokens.
              </p>
            </div>
            <TxComponents.action
              id="tx-transfer"
              action="transfer"
              label="Transfer"
              contract_label={@label}
              token_id={@token_id}
              confirm={"Transfer ENFT ##{@token_id} to {to}? Unclaimed balance goes with the ENFT. Claim first if you want to keep it."}
            >
              <input type="text" data-arg="to" placeholder="Recipient address" autocomplete="off" />
            </TxComponents.action>
            <p class="note">
              Unclaimed balance goes with the ENFT. Claim first if you want to keep it.
            </p>
          </div>

          <div
            :if={donations_open?(@enft, @settled)}
            class="area panel"
            data-activity-id="panel:enft:donate"
          >
            <h2>Donate</h2>
            <TxComponents.action
              :if={@address}
              id="tx-donate"
              action="donate"
              label="Donate"
              contract_label={@label}
              token_id={@token_id}
              decimals={@token_meta && @token_meta.decimals}
              symbol={@token_meta && @token_meta.symbol}
              confirm={"Donate {amount} {symbol} to ENFT ##{@token_id}? This cannot be undone."}
            >
              <input
                type="text"
                inputmode="decimal"
                data-arg="amount"
                placeholder="Amount"
                autocomplete="off"
              />
            </TxComponents.action>
            <p :if={!@address}>Connect a wallet to donate.</p>
            <p class="note">Encrypted before it leaves your browser.</p>
          </div>

          <div class="area panel" data-activity-id="panel:enft:maintenance">
            <h2>Maintenance</h2>
            <TxComponents.action
              id="tx-accrue"
              action="accrue"
              label="Update accrual"
              contract_label={@label}
              token_id={@token_id}
            />
            <p class="note">
              Moves earned payouts into the claimable balance. Anyone may do this.
            </p>
          </div>

          <div class="area panel" data-activity-id="panel:enft:sell">
            <h2>Sell</h2>
            <button type="button" disabled>Sell</button>
            <span class="soon">Coming soon</span>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
