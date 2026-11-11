defmodule Annuart.Repo do
  use Ecto.Repo,
    otp_app: :annuart,
    adapter: Ecto.Adapters.SQLite3
end
