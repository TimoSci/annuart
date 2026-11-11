defmodule Annuart.Repo.Migrations.CreateEnfts do
  use Ecto.Migration

  def change do
    create table(:enfts) do
      add :label, :string, null: false
      add :nft, :string, null: false
      add :token_id, :integer, null: false
      add :creator, :string, null: false
      add :owner, :string, null: false
      add :created_at, :utc_datetime, null: false
      add :created_block, :integer, null: false
      # uint64, stored as text (SQLite integers are signed); see Annuart.Enfts.Uint64.
      add :schedule_start, :string, null: false
      add :top_ups_allowed, :boolean, null: false, default: false
      # JSON list of %{"duration", "rate_per_sec"}; NULL when the schedule is hidden.
      add :schedule, :text
    end

    create unique_index(:enfts, [:nft, :token_id])
    create index(:enfts, [:label])
    create index(:enfts, [:owner])

    create table(:transfers) do
      add :enft_id, references(:enfts, on_delete: :delete_all), null: false
      add :from, :string, null: false
      add :to, :string, null: false
      add :block_number, :integer, null: false
      add :log_index, :integer, null: false
      add :tx_hash, :string, null: false
      add :at, :utc_datetime, null: false
    end

    create unique_index(:transfers, [:tx_hash, :log_index])
    create index(:transfers, [:enft_id])

    create table(:cursors) do
      add :nft, :string, null: false
      add :last_block, :integer, null: false
      add :last_block_hash, :string, null: false
    end

    create unique_index(:cursors, [:nft])
  end
end
