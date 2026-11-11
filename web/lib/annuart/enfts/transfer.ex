defmodule Annuart.Enfts.Transfer do
  @moduledoc "One ERC-721 Transfer log of an ENFT. Unique on `(tx_hash, log_index)`."
  use Ecto.Schema
  import Ecto.Changeset

  schema "transfers" do
    belongs_to :enft, Annuart.Enfts.Enft
    field :from, :string
    field :to, :string
    field :block_number, :integer
    field :log_index, :integer
    field :tx_hash, :string
    field :at, :utc_datetime
  end

  @fields ~w(enft_id from to block_number log_index tx_hash at)a

  def changeset(transfer, attrs) do
    transfer
    |> cast(attrs, @fields)
    |> validate_required(@fields)
    |> update_change(:from, &String.downcase/1)
    |> update_change(:to, &String.downcase/1)
    |> update_change(:tx_hash, &String.downcase/1)
    |> unique_constraint([:tx_hash, :log_index])
  end
end
