defmodule Annuart.Enfts.Payout do
  @moduledoc """
  One automatic payout of an ENFT, named by its request id. Filled by a
  `PayoutRequested` event and completed by the `PayoutPaid` event; either may be
  indexed first. The request side is nil when only the payment was seen. Amounts
  are public chain data.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Annuart.Enfts.BigUint

  schema "payouts" do
    belongs_to :enft, Annuart.Enfts.Enft
    field :request_id, :string
    field :recipient, :string
    field :requester, :string
    field :fee_offered, BigUint
    field :requested_at, :utc_datetime
    field :requested_block, :integer
    # The whole payout, fee included.
    field :amount_wei, BigUint
    # The fee actually paid to the requester.
    field :fee_wei, BigUint
    field :paid_in_weth, :boolean
    field :paid_at, :utc_datetime
    field :paid_block, :integer
    field :tx_hash, :string
  end

  @request_fields ~w(recipient requester fee_offered requested_at requested_block)a
  @paid_fields ~w(amount_wei fee_wei paid_in_weth paid_at paid_block tx_hash)a

  @doc "Fields set by a `PayoutRequested` event."
  def request_fields, do: @request_fields
  @doc "Fields set by a `PayoutPaid` event."
  def paid_fields, do: @paid_fields

  def request_changeset(payout, attrs) do
    payout
    |> cast(attrs, [:request_id | @request_fields])
    |> validate_required([:request_id | @request_fields])
    |> normalize()
  end

  def paid_changeset(payout, attrs) do
    payout
    |> cast(attrs, [:request_id | @paid_fields])
    |> validate_required([:request_id | @paid_fields])
    |> normalize()
  end

  defp normalize(changeset) do
    Enum.reduce(~w(request_id recipient requester tx_hash)a, changeset, fn field, cs ->
      update_change(cs, field, &String.downcase/1)
    end)
  end
end
