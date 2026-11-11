defmodule Annuart.Chain.Config do
  @moduledoc """
  The chain this instance talks to: chain id, RPC URL and the deployed
  `EndowmentNFT` contracts. Contracts come from the deployment file written
  by `scripts/deploy.ts`; `config/runtime.exs` loads it into the `:chain`
  application env. Everything here is public data.
  """
  require Logger

  defmodule Contract do
    @moduledoc "One deployed `EndowmentNFT` and its confidential token. Addresses are lowercased."
    @enforce_keys [:label, :nft, :token, :token_kind, :deploy_block]
    defstruct [:label, :nft, :token, :token_kind, :underlying, :deploy_block]

    @type t :: %__MODULE__{
            label: String.t(),
            nft: String.t(),
            token: String.t(),
            token_kind: :mock | :wrapped | :plain,
            underlying: String.t() | nil,
            deploy_block: non_neg_integer
          }
  end

  @no_chain_id 0
  @default_rpc_url "http://127.0.0.1:8545"

  @token_kinds %{"mock" => :mock, "wrapped" => :wrapped, "plain" => :plain}

  @doc "Parses a deployment file."
  @spec load(String.t()) ::
          {:ok, %{chain_id: integer, contracts: [Contract.t()]}} | {:error, :enoent | :invalid}
  def load(path) do
    with {:ok, body} <- read(path),
         {:ok, json} <- decode(body),
         {:ok, parsed} <- parse(json) do
      {:ok, parsed}
    end
  end

  defp read(path) do
    case File.read(path) do
      {:ok, body} -> {:ok, body}
      {:error, :enoent} -> {:error, :enoent}
      {:error, _} -> {:error, :invalid}
    end
  end

  defp decode(body) do
    case Jason.decode(body) do
      {:ok, json} -> {:ok, json}
      {:error, _} -> {:error, :invalid}
    end
  end

  defp parse(%{"chainId" => chain_id, "contracts" => contracts})
       when is_integer(chain_id) and is_list(contracts) do
    contracts
    |> Enum.reduce_while({:ok, []}, fn raw, {:ok, acc} ->
      case parse_contract(raw) do
        {:ok, contract} -> {:cont, {:ok, [contract | acc]}}
        :error -> {:halt, {:error, :invalid}}
      end
    end)
    |> case do
      {:ok, acc} -> unique_labels(%{chain_id: chain_id, contracts: Enum.reverse(acc)})
      error -> error
    end
  end

  defp parse(_), do: {:error, :invalid}

  # An ENFT is named by (label, token id), so a label names one contract.
  defp unique_labels(%{contracts: contracts} = parsed) do
    labels = Enum.map(contracts, & &1.label)
    if Enum.uniq(labels) == labels, do: {:ok, parsed}, else: {:error, :invalid}
  end

  defp parse_contract(
         %{
           "label" => label,
           "nft" => nft,
           "token" => token,
           "tokenKind" => kind,
           "deployBlock" => block
         } = raw
       )
       when is_binary(label) and is_binary(nft) and is_binary(token) and is_integer(block) and
              block >= 0 do
    underlying = Map.get(raw, "underlying")

    with {:ok, token_kind} <- Map.fetch(@token_kinds, kind),
         true <- is_nil(underlying) or is_binary(underlying) do
      {:ok,
       %Contract{
         label: label,
         nft: String.downcase(nft),
         token: String.downcase(token),
         token_kind: token_kind,
         underlying: underlying && String.downcase(underlying),
         deploy_block: block
       }}
    else
      _ -> :error
    end
  end

  defp parse_contract(_), do: :error

  @doc "Chain id of the running instance (0 when no deployment file could be loaded)."
  @spec chain_id() :: integer
  def chain_id, do: Keyword.get(chain_env(), :chain_id, @no_chain_id)

  @doc "Deployed contracts; empty when the deployment file could not be loaded."
  @spec contracts() :: [Contract.t()]
  def contracts, do: Keyword.get(chain_env(), :contracts, [])

  @spec contract(String.t()) :: Contract.t() | nil
  def contract(label), do: Enum.find(contracts(), &(&1.label == label))

  @spec rpc_url() :: String.t()
  def rpc_url, do: Keyword.get(chain_env(), :rpc_url, @default_rpc_url)

  @local_chain 31_337
  @default_log_chunk 2_000

  @doc """
  RPC URL the browser may use, from `ANNUART_PUBLIC_RPC_URL`; `nil` when unset
  or blank. The server's own URL usually carries a provider key and is never
  published through this function.
  """
  @spec public_rpc_url() :: String.t() | nil
  def public_rpc_url do
    case Application.get_env(:annuart, :public_rpc_url) do
      url when is_binary(url) -> if String.trim(url) == "", do: nil, else: String.trim(url)
      _ -> nil
    end
  end

  @doc """
  Blocks the indexer stays behind the head. Defaults to 0 on the local chain
  (and when no chain is configured) and 2 elsewhere, where short reorgs happen.
  """
  @spec confirmations() :: non_neg_integer
  def confirmations do
    case Application.get_env(:annuart, :indexer_confirmations) do
      n when is_integer(n) and n >= 0 -> n
      _ -> if local_or_none?(), do: 0, else: 2
    end
  end

  @doc "Most blocks asked of the node in one `eth_getLogs` call."
  @spec log_chunk() :: pos_integer
  def log_chunk do
    case Application.get_env(:annuart, :indexer_chunk) do
      n when is_integer(n) and n >= 1 -> n
      _ -> @default_log_chunk
    end
  end

  @local_poll_ms 4_000
  @remote_poll_ms 12_000

  @doc """
  How often the indexer polls the chain, in milliseconds: `:indexer_interval_ms`
  when set (`ANNUART_POLL_MS`), else 4 s on the local chain (and when no chain
  is configured) and 12 s elsewhere, where the provider is usually metered.
  """
  @spec poll_ms() :: pos_integer
  def poll_ms do
    case Application.get_env(:annuart, :indexer_interval_ms) do
      n when is_integer(n) and n >= 1 -> n
      _ -> if local_or_none?(), do: @local_poll_ms, else: @remote_poll_ms
    end
  end

  @doc """
  How long a creator waits for the indexer to show a new ENFT, in milliseconds.
  Off the local chain it also covers one poll interval.
  """
  @spec index_wait_ms() :: pos_integer
  def index_wait_ms do
    base = 20_000 + confirmations() * 15_000
    if local_or_none?(), do: base, else: base + poll_ms()
  end

  defp local_or_none?, do: chain_id() in [@local_chain, @no_chain_id]

  @doc """
  Loads the deployment file named by the `:deployments_path` and `:rpc_url`
  application env (set in `runtime.exs`) into the `:chain` env. Called once at
  application start. Does nothing when `:chain` is already configured.
  """
  @spec init() :: :ok
  def init do
    if Application.get_env(:annuart, :chain) == nil do
      path = Application.get_env(:annuart, :deployments_path, "../deployments/localhost.json")
      rpc_url = Application.get_env(:annuart, :rpc_url, @default_rpc_url)
      Application.put_env(:annuart, :chain, env_from_file(path, rpc_url))
      warn_withheld_rpc_url()
    end

    :ok
  end

  @doc """
  Logs a warning when the page will carry no RPC URL on chain 31337 because the
  server's URL is not a loopback one (the dev login reads the chain through it).
  The URL itself is not logged. Called by `init/0`.
  """
  @spec warn_withheld_rpc_url() :: :ok
  def warn_withheld_rpc_url do
    if chain_id() == @local_chain and public_rpc_url() == nil and not loopback?(rpc_url()) do
      Logger.warning(
        "chain 31337 with a server RPC URL that is not a loopback address: the page gets no RPC URL, " <>
          "and the dev login needs a loopback RPC URL (localhost, 127.0.0.1 or [::1])"
      )
    end

    :ok
  end

  @doc """
  Builds the `:chain` application env from the deployment file at `path`.
  A missing or invalid file yields no contracts and a logged warning.
  """
  @spec env_from_file(String.t(), String.t()) :: keyword
  def env_from_file(path, rpc_url) do
    case load(path) do
      {:ok, %{chain_id: chain_id, contracts: contracts}} ->
        [chain_id: chain_id, rpc_url: rpc_url, contracts: contracts]

      {:error, reason} ->
        Logger.warning("could not load deployments from #{path}: #{reason}; no contracts")
        [chain_id: @no_chain_id, rpc_url: rpc_url, contracts: []]
    end
  end

  @doc "Public chain data in the deployment-file shape, for the page's meta tag."
  @spec public() :: map
  def public do
    %{
      chainId: chain_id(),
      rpcUrl: browser_rpc_url(),
      contracts:
        Enum.map(contracts(), fn c ->
          %{
            label: c.label,
            nft: c.nft,
            token: c.token,
            tokenKind: Atom.to_string(c.token_kind),
            underlying: c.underlying,
            deployBlock: c.deploy_block
          }
        end)
    }
  end

  # The server URL only reaches the page on the local chain, and only when it
  # is a loopback address, so it carries no provider key. The chain id comes
  # from the deployment file, not from the RPC, so it alone proves nothing.
  defp browser_rpc_url do
    cond do
      url = public_rpc_url() -> url
      chain_id() == @local_chain and loopback?(rpc_url()) -> rpc_url()
      true -> nil
    end
  end

  @loopback_hosts ["localhost", "127.0.0.1", "::1", "[::1]"]

  defp loopback?(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host} when scheme in ["http", "https", "ws", "wss"] ->
        is_binary(host) and String.downcase(host) in @loopback_hosts

      _ ->
        false
    end
  end

  defp loopback?(_), do: false

  defp chain_env, do: Application.get_env(:annuart, :chain, [])
end
