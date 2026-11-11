defmodule AnnuartWeb.EnftFixtures do
  @moduledoc "Seeds ENFTs, the chain config and canned RPC reads for LiveView tests."
  alias Annuart.Chain.{Abi, Config}
  alias Annuart.{Enfts, RpcStub}

  @nft "0x" <> String.duplicate("a1", 20)
  @token "0x" <> String.duplicate("b2", 20)
  @owner "0x" <> String.duplicate("00", 18) <> "11ce"
  @creator "0x" <> String.duplicate("00", 18) <> "c0de"
  @max 18_446_744_073_709_551_615

  def nft, do: @nft
  def token, do: @token
  def owner, do: @owner
  def creator, do: @creator
  def indefinite, do: @max

  @doc "Points `:chain` at one `mock` contract. Restores the old value on exit."
  def put_chain(ctx_on_exit) do
    previous = Application.fetch_env(:annuart, :chain)

    ctx_on_exit.(fn ->
      case previous do
        {:ok, v} -> Application.put_env(:annuart, :chain, v)
        :error -> Application.delete_env(:annuart, :chain)
      end
    end)

    Application.put_env(:annuart, :chain,
      chain_id: 31337,
      rpc_url: "http://127.0.0.1:8545",
      contracts: [
        %Config.Contract{
          label: "mock",
          nft: @nft,
          token: @token,
          token_kind: :mock,
          deploy_block: 0
        }
      ]
    )
  end

  def mint(overrides \\ []) do
    attrs =
      Map.merge(
        %{
          label: "mock",
          nft: @nft,
          token_id: 1,
          creator: @creator,
          owner: @owner,
          created_at: ~U[2026-11-12 14:03:00Z],
          created_block: 1,
          schedule_start: 1_796_083_200,
          top_ups_allowed: true,
          schedule: [%{"duration" => 86_400, "rate_per_sec" => 1}]
        },
        Map.new(overrides)
      )

    {:ok, enft} = Enfts.record_mint(attrs)
    enft
  end

  def transfer(enft, from, to, block, at) do
    Enfts.record_transfer(%{
      enft_id: enft.id,
      from: from,
      to: to,
      block_number: block,
      log_index: 0,
      tx_hash: "0x" <> String.pad_leading(Integer.to_string(block, 16), 64, "0"),
      at: at
    })
  end

  @doc "Stubs token metadata and, optionally, last accrual and settled for ENFT `id`."
  def stub_reads(id, opts \\ []) do
    RpcStub.put_call(@token, Abi.encode_call(:symbol, []), {:ok, string_hex("TKN")})
    RpcStub.put_call(@token, Abi.encode_call(:decimals, []), {:ok, word(0)})

    RpcStub.put_call(
      @nft,
      Abi.encode_call(:last_accrual_at_of, [id]),
      {:ok, word(Keyword.get(opts, :last_accrual_at, 1_796_100_000))}
    )

    RpcStub.put_call(
      @nft,
      Abi.encode_call(:settled_of, [id]),
      {:ok, word(if Keyword.get(opts, :settled, false), do: 1, else: 0)}
    )
  end

  def word(n), do: "0x" <> String.pad_leading(Integer.to_string(n, 16), 64, "0")

  defp string_hex(s) do
    pad = String.pad_trailing(Base.encode16(s, case: :lower), 64, "0")

    "0x" <>
      String.pad_leading("20", 64, "0") <>
      String.pad_leading(Integer.to_string(byte_size(s), 16), 64, "0") <> pad
  end
end
