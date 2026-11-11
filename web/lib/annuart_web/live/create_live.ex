defmodule AnnuartWeb.CreateLive do
  @moduledoc """
  The form for creating an ENFT. The whole form is one `phx-update="ignore"`
  region driven by the `CreateForm` hook (`assets/js/hooks/create_form.js`):
  the amount, schedule and options are read, validated, encrypted and sent to
  the chain in the browser, and nothing typed here reaches the server. After
  the transaction is mined the hook reports `tx:confirmed` with the new ENFT's
  label, token id and transaction hash, and this view navigates to it.

  Inputs carry `data-role` and no `name`, and the form has no `phx-change` or
  `phx-submit`.
  """
  use AnnuartWeb, :live_view

  alias Annuart.Chain.{Config, Reader}
  alias Annuart.Enfts
  alias Annuart.Indexer
  alias AnnuartWeb.Layouts

  def mount(_params, _session, socket) do
    {:ok, assign(socket, page_title: "Create an ENFT", tokens: tokens(), created: nil)}
  end

  # The browser reports a mined creation. Only these four public values are read
  # from the event; anything else in it is ignored, never stored. The ENFT may
  # not be indexed yet, so navigation waits until it is (see `arrived/3`).
  def handle_event(
        "tx:confirmed",
        %{"action" => "createEnft", "label" => label, "tokenId" => token_id, "hash" => hash},
        socket
      )
      when is_binary(label) and is_binary(hash) do
    with %Config.Contract{} <- Config.contract(label),
         {:ok, id} <- token_id(token_id) do
      if Enfts.get_enft(label, id) do
        {:noreply, push_navigate(socket, to: ~p"/enft/#{label}/#{id}")}
      else
        if connected?(socket), do: Phoenix.PubSub.subscribe(Annuart.PubSub, "enfts")
        Indexer.sync_now()
        Process.send_after(self(), {:wait_timeout, label, id}, wait_ms())
        {:noreply, assign(socket, created: %{label: label, id: id, hash: hash, timed_out: false})}
      end
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("tx:confirmed", _params, socket), do: {:noreply, socket}

  def handle_info({:enft_changed, label, id}, socket), do: {:noreply, arrived(socket, label, id)}

  def handle_info(:enfts_reset, socket) do
    case socket.assigns.created do
      %{label: label, id: id} -> {:noreply, arrived(socket, label, id)}
      nil -> {:noreply, socket}
    end
  end

  def handle_info({:wait_timeout, label, id}, socket) do
    case socket.assigns.created do
      %{label: ^label, id: ^id} = created ->
        {:noreply, assign(socket, :created, %{created | timed_out: true})}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  defp arrived(socket, label, id) do
    case socket.assigns.created do
      %{label: ^label, id: ^id, timed_out: false} ->
        if Enfts.get_enft(label, id),
          do: push_navigate(socket, to: ~p"/enft/#{label}/#{id}"),
          else: socket

      _ ->
        socket
    end
  end

  # A token id is a non-negative integer, given as an integer or decimal string.
  defp token_id(id) when is_integer(id) and id >= 0, do: {:ok, id}

  defp token_id(id) when is_binary(id) do
    if Regex.match?(~r/\A\d+\z/, id), do: {:ok, String.to_integer(id)}, else: :error
  end

  defp token_id(_), do: :error

  defp wait_ms, do: Application.get_env(:annuart, :create_wait_ms, 20_000)

  # Symbol and decimals of each configured token, for the hook to parse and show
  # amounts with. `nil` when the chain cannot be read; the hook then refuses.
  defp tokens do
    for %Config.Contract{label: label, token: token} <- Config.contracts() do
      case Reader.token_meta(token) do
        {:ok, %{symbol: symbol, decimals: decimals}} ->
          %{label: label, symbol: symbol, decimals: decimals}

        _ ->
          %{label: label, symbol: nil, decimals: nil}
      end
    end
  end

  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current={:create}>
      <h1>Create an ENFT</h1>
      <p :if={@address == nil}>Connect a wallet to create an ENFT.</p>
      <p :if={@created && !@created.timed_out} class="note">Created. Waiting for it to appear…</p>
      <p :if={@created && @created.timed_out} class="note">
        Your ENFT was created. It is taking longer than usual to appear.
        Transaction {@created.hash}.
        <.link navigate={~p"/enft/#{@created.label}/#{@created.id}"}>Open the ENFT page</.link>
      </p>
      <p :if={@address != nil and @tokens == []}>No ENFT contracts are configured.</p>

      <form
        :if={@address != nil and @tokens != []}
        id="create-form"
        class="create"
        phx-hook="CreateForm"
        phx-update="ignore"
        autocomplete="off"
      >
        <div class="area panel" data-activity-id="panel:create:endowment">
          <h2>1. Endowment</h2>
          <div class="field">
            <label>Token</label>
            <%= if length(@tokens) > 1 do %>
              <select data-role="token">
                <option
                  :for={t <- @tokens}
                  value={t.label}
                  data-label={t.label}
                  data-symbol={t.symbol}
                  data-decimals={t.decimals}
                >
                  {t.label} ({t.symbol})
                </option>
              </select>
            <% else %>
              <span
                :for={t <- @tokens}
                data-role="token"
                data-label={t.label}
                data-symbol={t.symbol}
                data-decimals={t.decimals}
              >
                {t.symbol}
              </span>
            <% end %>
          </div>
          <div class="field">
            <label>Amount</label>
            <input type="text" inputmode="decimal" data-role="amount" autocomplete="off" />
          </div>
          <div class="field">
            <label>Your balance</label>
            <span
              id="create-balance"
              phx-hook="SecretValue"
              data-role="balance"
              data-secret="balance"
              data-label={List.first(@tokens) && List.first(@tokens).label}
              data-symbol={List.first(@tokens) && List.first(@tokens).symbol}
              data-decimals={List.first(@tokens) && List.first(@tokens).decimals}
            >
            </span>
          </div>
          <p class="note">
            Encrypted in your browser. Nobody but you will ever know this number.
          </p>
        </div>

        <div class="area panel" data-activity-id="panel:create:schedule">
          <h2>2. Payout schedule</h2>
          <div data-role="periods"></div>
          <button type="button" data-role="add-period">+ Add period</button>
          <div class="bars" data-role="chart" role="img" aria-label="Payout schedule chart"></div>
          <p data-role="total" class="total"></p>
          <p class="note">A month is 30 days and a year is 365 days.</p>
        </div>

        <div class="area panel" data-activity-id="panel:create:options">
          <h2>3. Options</h2>
          <div class="field">
            <label>Payouts start</label>
            <select data-role="start-mode">
              <option value="now" selected>Now</option>
              <option value="at">On a date</option>
            </select>
            <input type="datetime-local" data-role="start-at" hidden />
          </div>
          <div class="field">
            <label>Allow donations</label>
            <input type="checkbox" data-role="donations" checked />
            <span class="note">Cannot be changed later.</span>
          </div>
          <div class="field">
            <label>Recipient</label>
            <select data-role="recipient-mode">
              <option value="me" selected>Me</option>
              <option value="other">Another address</option>
            </select>
            <input
              type="text"
              data-role="recipient"
              placeholder="0x…"
              autocomplete="off"
              hidden
            />
          </div>
        </div>

        <p data-role="warning" class="warning"></p>
        <p data-role="message" class="tx-message" role="alert"></p>
        <div data-role="summary" class="summary" hidden></div>
        <button type="button" data-role="run">Create ENFT</button>
        <ol class="steps"></ol>
      </form>
    </Layouts.app>
    """
  end
end
