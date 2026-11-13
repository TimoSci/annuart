defmodule Annuart.Txs.Tx do
  @moduledoc """
  One transaction that touched a configured ENFT contract or its confidential
  token. `nft` is the contract whose sync recorded it; a token shared by two
  contracts yields one row per contract. Everything here is public chain data.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Annuart.Enfts.BigUint

  schema "txs" do
    field :nft, :string
    field :label, :string
    field :tx_hash, :string
    field :block_number, :integer
    field :tx_index, :integer
    field :at, :utc_datetime
    field :from, :string
    field :to, :string
    field :kind, :string
    field :token_id, :integer
    field :amount, BigUint
    field :amount_unit, :string
    field :parties, :string
  end

  @required ~w(nft label tx_hash block_number tx_index at from kind parties)a
  @optional ~w(to token_id amount amount_unit)a

  def changeset(tx, attrs) do
    tx
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_inclusion(:amount_unit, ["wei", "token"])
    |> update_change(:nft, &String.downcase/1)
    |> update_change(:tx_hash, &String.downcase/1)
    |> update_change(:from, &String.downcase/1)
  end
end
