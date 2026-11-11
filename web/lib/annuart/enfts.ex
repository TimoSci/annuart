defmodule Annuart.Enfts do
  @moduledoc "Store of indexed ENFTs, their transfers and per-contract indexer cursors."
  import Ecto.Query

  alias Annuart.Chain.Config
  alias Annuart.Enfts.{Cursor, Enft, Transfer}
  alias Annuart.Repo

  @doc """
  Lists ENFTs. Options: `top_ups: true | false | nil`, `label: String.t | nil`,
  `sort: :newest | :oldest` (default `:newest`).
  """
  def list_enfts(opts \\ []) do
    sort = Keyword.get(opts, :sort, :newest)

    Enft
    |> filter_top_ups(Keyword.get(opts, :top_ups))
    |> filter_label(Keyword.get(opts, :label))
    |> order(sort)
    |> Repo.all()
  end

  defp filter_top_ups(query, nil), do: query

  defp filter_top_ups(query, flag) when is_boolean(flag),
    do: where(query, [e], e.top_ups_allowed == ^flag)

  defp filter_label(query, nil), do: query
  defp filter_label(query, label), do: where(query, [e], e.label == ^label)

  defp order(query, :newest), do: order_by(query, [e], desc: e.created_at, desc: e.id)
  defp order(query, :oldest), do: order_by(query, [e], asc: e.created_at, asc: e.id)

  @doc """
  The ENFT `token_id` of the contract configured under `label`, or `nil` when no
  contract has that label. Looked up by the contract's address: rows another
  deployment left under the same label are never found.
  """
  def get_enft(label, token_id) do
    case Config.contract(label) do
      %Config.Contract{nft: nft} -> Repo.get_by(Enft, nft: nft, token_id: token_id)
      nil -> nil
    end
  end

  def list_owned(address) do
    address = String.downcase(address)

    Enft
    |> where([e], e.owner == ^address)
    |> order_by([e], desc: e.created_at, desc: e.id)
    |> Repo.all()
  end

  @doc "Transfers of an ENFT, oldest first."
  def history(%Enft{id: id}) do
    Transfer
    |> where([t], t.enft_id == ^id)
    |> order_by([t], asc: t.block_number, asc: t.log_index)
    |> Repo.all()
  end

  @doc "Inserts an ENFT, or returns the existing one for the same `(nft, token_id)`."
  def record_mint(attrs) do
    changeset = Enft.changeset(%Enft{}, attrs)

    case Repo.insert(changeset, on_conflict: :nothing, conflict_target: [:nft, :token_id]) do
      {:ok, %Enft{id: nil}} ->
        {:ok,
         Repo.get_by!(Enft,
           nft: Ecto.Changeset.get_field(changeset, :nft),
           token_id: Ecto.Changeset.get_field(changeset, :token_id)
         )}

      other ->
        other
    end
  end

  @doc """
  Records a transfer and moves the ENFT's owner to the recipient of its latest transfer.
  The ENFT is named by `:enft_id` or by `:nft` and `:token_id`. A transfer of an ENFT that
  is not stored is ignored. Safe to repeat.
  """
  def record_transfer(attrs) do
    attrs = Map.new(attrs)

    with %Enft{id: id} <- find_enft(attrs) do
      Repo.transaction(fn ->
        %Transfer{}
        |> Transfer.changeset(Map.put(attrs, :enft_id, id))
        |> Repo.insert!(on_conflict: :nothing, conflict_target: [:tx_hash, :log_index])

        latest =
          Transfer
          |> where([t], t.enft_id == ^id)
          |> order_by([t], desc: t.block_number, desc: t.log_index)
          |> limit(1)
          |> Repo.one!()

        Enft |> where([e], e.id == ^id) |> Repo.update_all(set: [owner: latest.to])
      end)
    end

    :ok
  end

  defp find_enft(%{enft_id: id}), do: Repo.get(Enft, id)

  defp find_enft(%{nft: nft, token_id: token_id}),
    do: Repo.get_by(Enft, nft: String.downcase(nft), token_id: token_id)

  @doc "Removes a contract's ENFTs, their transfers and its cursor."
  def reset_contract(nft) do
    nft = String.downcase(nft)

    Repo.transaction(fn ->
      Repo.delete_all(from e in Enft, where: e.nft == ^nft)
      Repo.delete_all(from c in Cursor, where: c.nft == ^nft)
    end)

    :ok
  end

  @doc """
  Removes the ENFTs (with their transfers) and cursors of every contract whose
  address is not in `nfts`. Returns whether anything was removed.
  """
  def delete_unconfigured(nfts) do
    nfts = Enum.map(nfts, &String.downcase/1)

    {:ok, removed} =
      Repo.transaction(fn ->
        {enfts, _} = Repo.delete_all(from e in Enft, where: e.nft not in ^nfts)
        {cursors, _} = Repo.delete_all(from c in Cursor, where: c.nft not in ^nfts)
        enfts + cursors
      end)

    removed > 0
  end

  def cursor(nft), do: Repo.get_by(Cursor, nft: String.downcase(nft))

  def put_cursor(nft, block, hash) do
    %Cursor{}
    |> Cursor.changeset(%{nft: nft, last_block: block, last_block_hash: hash})
    |> Repo.insert!(
      on_conflict: [set: [last_block: block, last_block_hash: hash]],
      conflict_target: :nft
    )

    :ok
  end
end
