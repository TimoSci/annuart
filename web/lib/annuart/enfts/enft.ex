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
    # The public name set at mint, or nil. Not unique: see Annuart.Enfts.Name.
    field :name, :string
    # List of %{"duration" => int, "rate_per_sec" => int}, or nil when hidden.
    field :schedule, {:array, :map}
    # Automatic payout settings: nil on a standard contract's ENFTs. Public chain data.
    field :auto_enabled, :boolean
    field :auto_interval, :integer
    field :auto_fee, Annuart.Enfts.BigUint
    # Request id of the payout asked for and not yet paid, or nil.
    field :pending_request_id, :string
    has_many :transfers, Annuart.Enfts.Transfer
    has_many :payouts, Annuart.Enfts.Payout
  end

  @fields ~w(label nft token_id creator owner created_at created_block schedule_start top_ups_allowed schedule name)a
  @required @fields -- [:schedule, :name]
  @addresses ~w(nft creator owner)a

  def changeset(enft, attrs) do
    enft
    |> cast(attrs, @fields)
    |> update_change(:schedule, &normalize_schedule/1)
    |> validate_required(@required)
    |> validate_change(:name, fn :name, name ->
      if Annuart.Enfts.Name.valid?(name), do: [], else: [name: "is not a valid name"]
    end)
    |> downcase(@addresses)
    |> unique_constraint([:nft, :token_id])
  end

  @doc "Changeset for the automatic payout settings, which only their events set."
  def auto_changeset(enft, attrs) do
    enft
    |> cast(attrs, [:auto_enabled, :auto_interval, :auto_fee])
    |> validate_required([:auto_enabled, :auto_interval, :auto_fee])
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
