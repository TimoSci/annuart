defmodule Annuart.Enfts do
  @moduledoc "Store of indexed ENFTs, their transfers, automatic payouts and per-contract indexer cursors."
  import Ecto.Query

  alias Annuart.Chain.Config
  alias Annuart.Enfts.{Cursor, Enft, Payout, Transfer}
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

  @doc """
  Stores the automatic payout settings of an ENFT named by `:nft` and `:token_id`:
  `:enabled`, `:interval` (seconds) and `:fee` (wei). A token that is not stored is
  ignored. Safe to repeat.
  """
  def record_auto_settings(%{enabled: enabled, interval: interval, fee: fee} = attrs) do
    with %Enft{} = enft <- find_enft(attrs) do
      enft
      |> Enft.auto_changeset(%{auto_enabled: enabled, auto_interval: interval, auto_fee: fee})
      |> Repo.update!()
    end

    :ok
  end

  @doc """
  Records a `PayoutRequested` event. Attrs: `:nft`, `:token_id`, `:request_id`, `:recipient`,
  `:requester`, `:fee_offered`, `:requested_at`, `:requested_block`. Fills the payout row of
  the request (creating it if needed) and marks the request pending unless it is already
  paid. A token that is not stored is ignored. Safe to repeat.
  """
  def record_payout_requested(attrs) do
    upsert_payout(attrs, :request_changeset, Payout.request_fields(), fn enft, payout ->
      if is_nil(payout.paid_at) and enft.pending_request_id != payout.request_id,
        do: set_pending(enft, payout.request_id)
    end)
  end

  @doc """
  Records a `PayoutPaid` event. Attrs: `:nft`, `:token_id`, `:request_id`, `:amount_wei` (the
  whole payout), `:fee_wei`, `:paid_in_weth`, `:paid_at`, `:paid_block`, `:tx_hash`. Completes
  the payout row of the request, creating it if the request was never seen, and clears the
  pending request when it is this one. A token that is not stored is ignored. Safe to repeat.
  """
  def record_payout_paid(attrs) do
    upsert_payout(attrs, :paid_changeset, Payout.paid_fields(), fn enft, payout ->
      if enft.pending_request_id == payout.request_id, do: set_pending(enft, nil)
    end)
  end

  defp upsert_payout(attrs, changeset_fun, fields, after_upsert) do
    attrs = Map.new(attrs)

    with %Enft{} = enft <- find_enft(attrs) do
      changeset = apply(Payout, changeset_fun, [%Payout{enft_id: enft.id}, attrs])

      Repo.transaction(fn ->
        case Repo.insert(changeset,
               on_conflict: {:replace, fields},
               conflict_target: [:enft_id, :request_id]
             ) do
          {:ok, _} ->
            payout =
              Repo.get_by!(Payout, enft_id: enft.id, request_id: changeset.changes.request_id)

            after_upsert.(Repo.get!(Enft, enft.id), payout)
            :ok

          {:error, changeset} ->
            Repo.rollback(changeset)
        end
      end)
      |> case do
        {:ok, :ok} -> :ok
        {:error, changeset} -> {:error, changeset}
      end
    else
      _ -> :ok
    end
  end

  defp set_pending(%Enft{id: id}, request_id),
    do: Enft |> where([e], e.id == ^id) |> Repo.update_all(set: [pending_request_id: request_id])

  @doc "Payouts of an ENFT, newest first."
  def list_payouts(%Enft{id: id}) do
    Payout
    |> where([p], p.enft_id == ^id)
    |> order_by([p], desc: coalesce(p.requested_block, p.paid_block), desc: p.id)
    |> Repo.all()
  end

  @doc "The latest paid payout of an ENFT, or `nil`."
  def last_payout(%Enft{id: id}) do
    Payout
    |> where([p], p.enft_id == ^id and not is_nil(p.paid_at))
    |> order_by([p], desc: p.paid_block, desc: p.id)
    |> limit(1)
    |> Repo.one()
  end

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
