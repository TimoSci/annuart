defmodule Annuart.Enfts.Enft do
  @moduledoc "An endowment NFT, identified on chain by `(nft, token_id)` and to users by `(label, token_id)`."
  use Ecto.Schema
  import Ecto.Changeset

  schema "enfts" do
    field :label, :string
    field :nft, :string
    field :token_id, :integer
    field :creator, :string
    field :owner, :string
    field :created_at, :utc_datetime
    field :created_block, :integer
    field :schedule_start, Annuart.Enfts.Uint64
    field :top_ups_allowed, :boolean, default: false
    # List of %{"duration" => int, "rate_per_sec" => int}, or nil when hidden.
    field :schedule, {:array, :map}
    has_many :transfers, Annuart.Enfts.Transfer
  end

  @fields ~w(label nft token_id creator owner created_at created_block schedule_start top_ups_allowed schedule)a
  @required @fields -- [:schedule]
  @addresses ~w(nft creator owner)a

  def changeset(enft, attrs) do
    enft
    |> cast(attrs, @fields)
    |> update_change(:schedule, &normalize_schedule/1)
    |> validate_required(@required)
    |> downcase(@addresses)
    |> unique_constraint([:nft, :token_id])
  end

  defp downcase(changeset, fields) do
    Enum.reduce(fields, changeset, &update_change(&2, &1, fn v -> String.downcase(v) end))
  end

  # Segments are stored string-keyed so they survive a JSON round trip unchanged.
  defp normalize_schedule(nil), do: nil

  defp normalize_schedule(segments) when is_list(segments) do
    Enum.map(segments, fn seg ->
      %{
        "duration" => seg[:duration] || seg["duration"],
        "rate_per_sec" => seg[:rate_per_sec] || seg["rate_per_sec"]
      }
    end)
  end
end
