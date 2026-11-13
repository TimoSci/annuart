defmodule AnnuartWeb.TxComponents do
  @moduledoc """
  The button-plus-step-list every chain action uses. The `TxAction` hook (see
  `assets/js/hooks/tx_action.js`) reads the inputs in the slot, runs the action
  in the browser and draws the steps. LiveView never touches this region
  (`phx-update="ignore"`), and inputs in it must carry `data-arg` and no `name`,
  so no amount can reach the server.

  The confirmation is `data-question`, not `data-confirm`: phoenix_html asks
  its own `window.confirm` for any click inside an element with
  `data-confirm`, which would show the question a second time, unfilled.
  """
  use Phoenix.Component

  attr :id, :string, required: true
  attr :action, :string, required: true, doc: "An action name from assets/js/chain/actions.js"
  attr :label, :string, required: true, doc: "The button text"
  attr :contract_label, :string, required: true
  attr :token_id, :integer, default: nil

  attr :confirm, :string,
    default: nil,
    doc: "A question asked before running; the hook fills in {amount}, {symbol} and {to}"

  attr :decimals, :integer, default: nil, doc: "The token's decimals, for amount inputs"
  attr :symbol, :string, default: nil
  slot :inner_block

  def action(assigns) do
    ~H"""
    <div
      id={@id}
      class="tx"
      phx-hook="TxAction"
      phx-update="ignore"
      data-action={@action}
      data-label={@contract_label}
      data-token-id={@token_id}
      data-question={@confirm}
      data-decimals={@decimals}
      data-symbol={@symbol}
    >
      {render_slot(@inner_block)}
      <button type="button" class="tx-run" data-role="run">{@label}</button>
      <ol class="steps"></ol>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :contract_label, :string, required: true
  attr :token_id, :integer, required: true

  @doc """
  Claims an ENFT's payout and pays it out as plain ETH. Only for ENFTs whose
  token is wrapped ETH; the caller decides whether to render it.
  """
  def claim_to_eth(assigns) do
    ~H"""
    <.action
      id={@id}
      action="claimToEth"
      label="Claim and convert to ETH"
      contract_label={@contract_label}
      token_id={@token_id}
      confirm="Claim the payout and convert it to ETH? The amount converted becomes public. Your wallet will ask you to confirm four transactions."
    />
    """
  end
end
