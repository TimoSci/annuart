defmodule Annuart.Indexer do
  @moduledoc """
  Follows the chain and mirrors every configured `EndowmentNFT`'s public events
  into the `Annuart.Enfts` store. Anyone can emit events, so a log the indexer
  cannot make sense of is skipped, never fatal.

  `sync_once/0` does one pass and is a pure function of chain state and the
  database; the GenServer only calls it on a timer (and on `sync_now/0`).
  After a pass it broadcasts `{:enft_changed, label, token_id}` on the
  `"enfts"` topic of `Annuart.PubSub` for every ENFT touched, and
  `:enfts_reset` when a contract was rebuilt from scratch or the rows of a
  contract no longer configured were removed.
  """
  use GenServer
  require Logger

  alias Annuart.Chain.{Abi, Config, Reader}
  alias Annuart.Enfts

  @topic "enfts"
  @chunk 2_000
  @zero "0x0000000000000000000000000000000000000000"

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Asks the running indexer to sync immediately."
  @spec sync_now() :: :ok
  def sync_now, do: GenServer.cast(__MODULE__, :sync)

  @doc "One pass over every configured contract. Never raises."
  @spec sync_once() :: :ok
  def sync_once do
    contracts = Config.contracts()
    removed = delete_unconfigured(contracts)
    Enum.each(contracts, &sync_contract/1)
    if removed, do: broadcast(:enfts_reset)
    :ok
  end

  # A redeploy can leave rows of an address that is no longer in the
  # deployment file; they would show a dead contract's ENFTs.
  defp delete_unconfigured(contracts) do
    Enfts.delete_unconfigured(Enum.map(contracts, & &1.nft))
  rescue
    e ->
      Logger.warning("indexer: removing unconfigured contracts failed: #{Exception.message(e)}")
      false
  end

  ## GenServer

  @impl true
  def init(_opts) do
    send(self(), :poll)
    {:ok, %{}}
  end

  @impl true
  def handle_cast(:sync, state) do
    sync_once()
    {:noreply, state}
  end

  @impl true
  def handle_info(:poll, state) do
    sync_once()
    Process.send_after(self(), :poll, Application.get_env(:annuart, :indexer_interval_ms, 4_000))
    {:noreply, state}
  end

  ## One contract

  defp sync_contract(contract) do
    case do_sync(contract) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("indexer: #{contract.label}: stopped this pass: #{inspect(reason)}")
    end
  rescue
    e -> Logger.warning("indexer: #{contract.label}: failed: #{Exception.message(e)}")
  end

  defp do_sync(contract) do
    with {:ok, code} <- rpc().get_code(contract.nft),
         {:ok, head} <- rpc().block_number() do
      cond do
        code == "0x" ->
          Logger.warning(
            "indexer: #{contract.label}: no contract code at #{contract.nft}, skipping"
          )

        contract.deploy_block > head ->
          Logger.warning(
            "indexer: #{contract.label}: deploy block #{contract.deploy_block} is above head #{head}, skipping"
          )

        true ->
          with {:ok, cursor} <- check_reset(contract, head) do
            from = if cursor, do: cursor.last_block + 1, else: contract.deploy_block
            with :ok <- sync_range(contract, from, head), do: announce_reset(contract)
          end
      end
    end
  end

  # Returns the cursor to continue from, or nil after wiping a contract that
  # no longer matches the chain (restart, or a chain that is shorter).
  defp check_reset(contract, head) do
    case Enfts.cursor(contract.nft) do
      nil ->
        {:ok, nil}

      cursor when head < cursor.last_block ->
        reset(contract, "head #{head} is below the cursor #{cursor.last_block}")

      cursor ->
        case rpc().block(cursor.last_block) do
          {:ok, %{hash: hash}} when hash == cursor.last_block_hash -> {:ok, cursor}
          {:ok, _} -> reset(contract, "block hash at the cursor changed")
          {:error, :not_found} -> reset(contract, "cursor block no longer exists")
          {:error, _} = error -> error
        end
    end
  end

  defp reset(contract, why) do
    Logger.warning("indexer: #{contract.label}: #{why}, rebuilding")
    Enfts.reset_contract(contract.nft)
    # Remembered outside the database (the cursor is gone) so a rebuild that
    # fails part-way is still announced once a later pass completes it.
    :persistent_term.put(reset_key(contract), true)
    {:ok, nil}
  end

  defp announce_reset(contract) do
    if :persistent_term.get(reset_key(contract), false) do
      :persistent_term.erase(reset_key(contract))
      broadcast(:enfts_reset)
    end

    :ok
  end

  defp reset_key(contract), do: {__MODULE__, :reset_pending, contract.nft}

  defp sync_range(_contract, from, head) when from > head, do: :ok

  defp sync_range(contract, from, head) do
    to = min(from + @chunk - 1, head)

    with {:ok, logs} <- fetch_logs(contract, from, to),
         {:ok, touched} <- apply_logs(contract, logs),
         {:ok, %{hash: hash}} <- rpc().block(to) do
      Enfts.put_cursor(contract.nft, to, hash)
      Enum.each(touched, fn id -> broadcast({:enft_changed, contract.label, id}) end)
      sync_range(contract, to + 1, head)
    end
  end

  defp fetch_logs(contract, from, to) do
    rpc().get_logs(%{
      address: contract.nft,
      from_block: from,
      to_block: to,
      topics: [[Abi.topic(:endowment_minted), Abi.topic(:transfer)]]
    })
  end

  ## Applying logs

  defp apply_logs(contract, logs) do
    logs
    |> Enum.flat_map(&parse_log(contract, &1))
    |> Enum.sort_by(& &1.order)
    |> Enum.reduce_while({:ok, [], %{}}, fn entry, {:ok, touched, blocks} ->
      case apply_entry(contract, entry, blocks) do
        {:ok, id, blocks} -> {:cont, {:ok, [id | touched], blocks}}
        {:skip, blocks} -> {:cont, {:ok, touched, blocks}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, touched, _blocks} -> {:ok, touched |> Enum.reverse() |> Enum.uniq()}
      error -> error
    end
  end

  # A log that cannot be read in full is dropped with a warning.
  defp parse_log(contract, log) do
    event = Abi.decode_log(log)
    order = {to_int!(log["blockNumber"]), to_int!(log["logIndex"])}
    tx_hash = log["transactionHash"]
    unless is_binary(tx_hash), do: raise(ArgumentError, "no transactionHash")

    case event do
      {_kind, _data} -> [%{event: event, order: order, tx_hash: tx_hash}]
      :unknown -> []
    end
  rescue
    e ->
      Logger.warning(
        "indexer: #{contract.label}: skipping undecodable log: #{Exception.message(e)}"
      )

      []
  end

  defp to_int!("0x" <> hex), do: String.to_integer(hex, 16)
  defp to_int!(n) when is_integer(n), do: n

  defp apply_entry(contract, %{event: {:minted, m}, order: {block, _}}, blocks) do
    with {:ok, ts, blocks} <- timestamp(block, blocks),
         {:ok, schedule} <- schedule(contract, m.token_id),
         {:ok, _} <-
           Enfts.record_mint(%{
             label: contract.label,
             nft: contract.nft,
             token_id: m.token_id,
             creator: m.creator,
             owner: m.to,
             created_at: DateTime.from_unix!(ts),
             created_block: block,
             schedule_start: m.schedule_start,
             top_ups_allowed: m.top_ups_allowed,
             schedule: schedule
           }) do
      {:ok, m.token_id, blocks}
    else
      {:error, %Ecto.Changeset{} = cs} ->
        Logger.warning("indexer: #{contract.label}: skipping invalid mint: #{inspect(cs.errors)}")
        {:skip, blocks}

      other ->
        other
    end
  end

  defp apply_entry(_contract, %{event: {:transfer, %{from: @zero}}}, blocks), do: {:skip, blocks}

  defp apply_entry(contract, %{event: {:transfer, t}, order: {block, index}} = entry, blocks) do
    with {:ok, ts, blocks} <- timestamp(block, blocks) do
      Enfts.record_transfer(%{
        nft: contract.nft,
        token_id: t.token_id,
        from: t.from,
        to: t.to,
        block_number: block,
        log_index: index,
        tx_hash: entry.tx_hash,
        at: DateTime.from_unix!(ts)
      })

      {:ok, t.token_id, blocks}
    end
  end

  defp schedule(contract, token_id) do
    case Reader.schedule(contract.nft, token_id) do
      {:ok, segments} -> {:ok, segments}
      {:error, :hidden} -> {:ok, nil}
      {:error, _} = error -> error
    end
  end

  defp timestamp(block, blocks) do
    case blocks do
      %{^block => ts} ->
        {:ok, ts, blocks}

      _ ->
        with {:ok, %{timestamp: ts}} <- rpc().block(block),
             do: {:ok, ts, Map.put(blocks, block, ts)}
    end
  end

  defp broadcast(message), do: Phoenix.PubSub.broadcast(Annuart.PubSub, @topic, message)

  defp rpc, do: Application.get_env(:annuart, :rpc, Annuart.Chain.Rpc)
end
