defmodule Annuart.Chain.Rpc do
  @moduledoc """
  Minimal JSON-RPC 2.0 client for the configured chain. Callers go through
  `Application.get_env(:annuart, :rpc, Annuart.Chain.Rpc)` so tests can stub it.
  """
  alias Annuart.Chain.Config

  @spec block_number() :: {:ok, integer} | {:error, term}
  def block_number do
    with {:ok, hex} <- call("eth_blockNumber", []), do: {:ok, to_int(hex)}
  end

  @spec block(integer) :: {:ok, %{hash: String.t(), timestamp: integer}} | {:error, term}
  def block(number) do
    case call("eth_getBlockByNumber", [to_hex(number), false]) do
      {:ok, %{"hash" => hash, "timestamp" => ts}} -> {:ok, %{hash: hash, timestamp: to_int(ts)}}
      {:ok, nil} -> {:error, :not_found}
      {:ok, other} -> {:error, {:bad_response, other}}
      error -> error
    end
  end

  @spec get_logs(map) :: {:ok, [map]} | {:error, term}
  def get_logs(%{address: address, from_block: from, to_block: to, topics: topics}) do
    call("eth_getLogs", [
      %{address: address, fromBlock: to_hex(from), toBlock: to_hex(to), topics: topics}
    ])
  end

  @spec eth_call(String.t(), String.t()) :: {:ok, String.t()} | {:error, term}
  def eth_call(to, data), do: call("eth_call", [%{to: to, data: data}, "latest"])

  @spec get_code(String.t()) :: {:ok, String.t()} | {:error, term}
  def get_code(address), do: call("eth_getCode", [address, "latest"])

  defp call(method, params) do
    body = %{jsonrpc: "2.0", id: 1, method: method, params: params}

    # Tests add `plug: {Req.Test, Annuart.Chain.Rpc}` through the app env.
    options = Application.get_env(:annuart, :rpc_req_options, [])

    case Req.post(Config.rpc_url(), [json: body, retry: false] ++ options) do
      {:ok, %{status: 200, body: %{"error" => error}}} -> {:error, rpc_error(error)}
      {:ok, %{status: 200, body: %{"result" => result}}} -> {:ok, result}
      {:ok, %{status: status}} -> {:error, {:http, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  # A revert carries its return data when the node provides it.
  defp rpc_error(%{"data" => "0x" <> _ = data, "message" => msg} = e) do
    if revert?(e, msg), do: {:revert, data}, else: {:rpc, e}
  end

  defp rpc_error(%{"message" => msg} = e),
    do: if(revert?(e, msg), do: {:revert, "0x"}, else: {:rpc, e})

  defp rpc_error(e), do: {:rpc, e}

  defp revert?(%{"code" => 3}, _), do: true
  defp revert?(_, msg), do: is_binary(msg) and String.contains?(String.downcase(msg), "revert")

  defp to_hex(n), do: "0x" <> String.downcase(Integer.to_string(n, 16))
  defp to_int("0x" <> hex), do: String.to_integer(hex, 16)
end
