defmodule Annuart.Enfts.Cursor do
  @moduledoc "How far the indexer has read one contract."
  use Ecto.Schema
  import Ecto.Changeset

  schema "cursors" do
    field :nft, :string
    field :last_block, :integer
    field :last_block_hash, :string
  end

  def changeset(cursor, attrs) do
    cursor
    |> cast(attrs, [:nft, :last_block, :last_block_hash])
    |> validate_required([:nft, :last_block, :last_block_hash])
    |> update_change(:nft, &String.downcase/1)
    |> unique_constraint(:nft)
  end
end
