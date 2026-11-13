defmodule Annuart.Txs do
  @moduledoc """
  Store of the transactions that touched a configured ENFT contract or its
  confidential token, and what each one did. Filled by `Annuart.Indexer`.

  A transaction is named by the function it called. Amounts are kept only when
  the chain shows them in the clear (a wrap, a finished unwrap, a paid automatic
  payout, the test-token faucet); an encrypted amount is never known here.
  """
  import Ecto.Query

  alias Annuart.Chain.Abi
  alias Annuart.Enfts.{Enft, Payout}
  alias Annuart.Repo
  alias Annuart.Txs.Tx

  @zero "0x0000000000000000000000000000000000000000"
  @max_token_id 9_223_372_036_854_775_807

  # selector => kind, by what the transaction was sent to.
  @nft_kinds %{
    "0xabb31629" => "create",
    "0x52f56bfd" => "create_auto",
    "0x022d6bc2" => "donate",
    "0x379607f5" => "claim",
    "0x744f4cf6" => "accrue",
    "0x42842e0e" => "transfer",
    "0xb88d4fde" => "transfer",
    "0x23b872dd" => "transfer",
    "0xbf279f7d" => "auto_settings",
    "0x10b59b7e" => "payout_request",
    "0x3210bfc2" => "payout_finalise"
  }
  @token_kinds %{
    "0xd4febb96" => "authorise",
    "0x2893c5b0" => "faucet",
    "0xbf376c7a" => "wrap",
    "0x5bf4ef06" => "unwrap_request",
    "0xe8c15fd4" => "unwrap_request",
    "0x5bb67a05" => "unwrap_finalise",
    "0x2fb74e62" => "token_transfer",
    "0x5bebed7e" => "token_transfer"
  }

  # Kinds whose amount is encrypted on chain.
  @private ~w(create create_auto donate claim unwrap_request token_transfer)

  @doc "Whether a transaction of this kind moves an encrypted amount."
  @spec private?(String.t()) :: boolean
  def private?(kind), do: kind in @private

  @doc """
  Describes a transaction from its sender, target and calldata (`tx`: `:from`,
  `:to`, `:input`) and the logs it left on `contract`'s addresses. Returns
  `:kind`, `:token_id`, `:amount`, `:amount_unit` and `:parties`, the addresses
  it involved.
  """
  def describe(contract, %{from: from, to: to, input: input}, logs) do
    kind = kind(contract, to, input)
    token_id = token_id(kind, input, logs)
    {amount, unit} = amount(kind, input, logs)

    parties =
      [from | Enum.flat_map(logs, &topic_addresses/1)] ++
        extra_parties(contract, kind, token_id, logs)

    %{
      kind: kind,
      token_id: token_id,
      amount: amount,
      amount_unit: unit,
      parties:
        parties
        |> Enum.map(&String.downcase/1)
        |> Enum.uniq()
        |> Enum.reject(&(&1 in [@zero, contract.nft, contract.token]))
    }
  end

  defp kind(contract, to, input) do
    selector = selector(input)

    cond do
      to == contract.nft -> Map.get(@nft_kinds, selector, "other")
      to == contract.token -> Map.get(@token_kinds, selector, "other")
      true -> "other"
    end
  end

  defp selector("0x" <> hex) when byte_size(hex) >= 8,
    do: "0x" <> String.downcase(binary_part(hex, 0, 8))

  defp selector(_), do: nil

  # The nth 32-byte argument word of the calldata, as an integer.
  defp word("0x" <> hex, n) when byte_size(hex) >= 8 + 64 * (n + 1) do
    case Integer.parse(binary_part(hex, 8 + 64 * n, 64), 16) do
      {value, ""} -> value
      _ -> nil
    end
  end

  defp word(_, _), do: nil

  defp token_id(kind, input, _logs)
       when kind in ~w(donate claim accrue auto_settings payout_request payout_finalise),
       do: small(word(input, 0))

  defp token_id("transfer", input, _logs), do: small(word(input, 2))

  defp token_id(kind, _input, logs) when kind in ["create", "create_auto"] do
    Enum.find_value(logs, fn log ->
      case decode(log) do
        {:minted, %{token_id: id}} -> small(id)
        _ -> nil
      end
    end)
  end

  defp token_id(_, _, _), do: nil

  defp small(n) when is_integer(n) and n <= @max_token_id, do: n
  defp small(_), do: nil

  defp amount("faucet", input, _), do: unit(word(input, 1), "token")
  defp amount("wrap", input, _), do: unit(word(input, 1), "wei")
  defp amount("unwrap_finalise", input, _), do: unit(word(input, 1), "token")

  # What the PayoutPaid event reports, fee included; the calldata amount otherwise.
  defp amount("payout_finalise", input, logs) do
    paid =
      Enum.find_value(logs, fn log ->
        case decode(log) do
          {:payout_paid, %{amount_wei: wei}} -> wei
          _ -> nil
        end
      end)

    if paid, do: {paid, "wei"}, else: unit(word(input, 1), "token")
  end

  defp amount(_, _, _), do: {nil, nil}

  defp unit(nil, _), do: {nil, nil}
  defp unit(value, unit), do: {value, unit}

  defp decode(log) do
    Abi.decode_log(log)
  rescue
    _ -> :unknown
  end

  # Indexed event arguments that are addresses: 12 zero bytes, then 20 bytes
  # that are not a small number (a token id is indexed the same way).
  defp topic_addresses(%{"topics" => [_ | indexed]}) do
    for "0x" <> hex <- indexed,
        byte_size(hex) == 64,
        binary_part(hex, 0, 24) == String.duplicate("0", 24),
        binary_part(hex, 24, 24) != String.duplicate("0", 24),
        do: "0x" <> binary_part(hex, 24, 40)
  end

  defp topic_addresses(_), do: []

  # People a transaction concerns who appear in none of its indexed arguments.
  defp extra_parties(contract, "donate", token_id, _logs) when is_integer(token_id) do
    case Repo.get_by(Enft, nft: contract.nft, token_id: token_id) do
      %Enft{owner: owner} -> [owner]
      nil -> []
    end
  end

  defp extra_parties(contract, "payout_finalise", token_id, logs) when is_integer(token_id) do
    request_ids =
      for log <- logs, {:payout_paid, %{request_id: id}} <- [decode(log)], do: id

    Payout
    |> join(:inner, [p], e in Enft, on: p.enft_id == e.id)
    |> where([p, e], e.nft == ^contract.nft and e.token_id == ^token_id)
    |> where([p], p.request_id in ^request_ids and not is_nil(p.recipient))
    |> select([p], p.recipient)
    |> Repo.all()
  end

  defp extra_parties(_, _, _, _), do: []

  @doc """
  Stores a transaction: the result of `describe/3` plus `:nft`, `:label`,
  `:tx_hash`, `:block_number`, `:tx_index`, `:at`, `:from` and `:to`. Safe to
  repeat. Returns `:ok`, or `{:error, changeset}` for attrs that cannot be stored.
  """
  def record(attrs) do
    attrs = Map.update!(Map.new(attrs), :parties, &(" " <> Enum.join(&1, " ") <> " "))

    case %Tx{}
         |> Tx.changeset(attrs)
         |> Repo.insert(on_conflict: :nothing, conflict_target: [:nft, :tx_hash]) do
      {:ok, _} -> :ok
      {:error, changeset} -> {:error, changeset}
    end
  end

  @doc """
  The latest `limit` transactions that involve `address`, newest first. A
  transaction recorded under two contracts (they share a token) is listed once,
  under the contract it was sent to when that is one of them.
  """
  def list_for(address, limit \\ 300) do
    pattern = "% " <> String.downcase(address) <> " %"

    Tx
    |> where([t], like(t.parties, ^pattern))
    |> order_by([t], desc: t.block_number, desc: t.tx_index, desc: t.nft == t.to, asc: t.id)
    |> limit(^(limit * 2))
    |> Repo.all()
    |> Enum.uniq_by(& &1.tx_hash)
    |> Enum.take(limit)
  end

  @doc "Removes the transactions recorded for a contract."
  def reset_contract(nft) do
    Repo.delete_all(from t in Tx, where: t.nft == ^String.downcase(nft))
    :ok
  end

  @doc "Removes the transactions of every contract not in `nfts`. Returns how many."
  def delete_unconfigured(nfts) do
    {n, _} =
      Repo.delete_all(from t in Tx, where: t.nft not in ^Enum.map(nfts, &String.downcase/1))

    n
  end
end
