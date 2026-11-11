defmodule Annuart.Repo.Migrations.AddNameToEnfts do
  use Ecto.Migration

  def change do
    alter table(:enfts) do
      # The public name set at mint; NULL when the ENFT has none.
      add :name, :string
    end
  end
end
