defmodule Annuart.Repo.Migrations.CreateTxs do
  use Ecto.Migration

  def change do
    # One transaction that touched a configured contract or its token, as seen by
    # that contract's sync. All of it is public chain data.
    create table(:txs) do
      add :nft, :string, null: false
      add :label, :string, null: false
      add :tx_hash, :string, null: false
      add :block_number, :integer, null: false
      add :tx_index, :integer, null: false
      add :at, :utc_datetime, null: false
      add :from, :string, null: false
      add :to, :string
      add :kind, :string, null: false
      add :token_id, :integer
      # A public amount, as text; NULL when the transaction has none or it is encrypted.
      add :amount, :string
      add :amount_unit, :string
      # Addresses involved, each surrounded by spaces: " 0xaa… 0xbb… ".
      add :parties, :text, null: false
    end

    create unique_index(:txs, [:nft, :tx_hash])
    create index(:txs, [:block_number])

    # Forget how far each contract was read, so the indexer reads every contract
    # again from its deploy block and records the transactions already on chain.
    # Re-reading is safe: what is stored for ENFTs is only written again.
    execute("DELETE FROM cursors", "")
  end
end
