defmodule Annuart.Repo.Migrations.AddAutoPayouts do
  use Ecto.Migration

  def change do
    alter table(:enfts) do
      # NULL on a standard contract's ENFTs. Wei values are text: see Annuart.Enfts.BigUint.
      add :auto_enabled, :boolean
      add :auto_interval, :integer
      add :auto_fee, :string
      add :pending_request_id, :string
    end

    create table(:payouts) do
      add :enft_id, references(:enfts, on_delete: :delete_all), null: false
      add :request_id, :string, null: false
      # Unknown (NULL) when the payment was indexed without its request.
      add :recipient, :string
      add :requester, :string
      add :fee_offered, :string
      add :requested_at, :utc_datetime
      add :requested_block, :integer
      # NULL until paid.
      add :amount_wei, :string
      add :fee_wei, :string
      add :paid_in_weth, :boolean
      add :paid_at, :utc_datetime
      add :paid_block, :integer
      add :tx_hash, :string
    end

    create unique_index(:payouts, [:enft_id, :request_id])
  end
end
