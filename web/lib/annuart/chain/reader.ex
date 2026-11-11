defmodule Annuart.Chain.Reader do
  @moduledoc """
  Typed reads of public contract state. A schedule is hidden from callers the
  contract's ACL does not allow, in which case the call reverts (or the
  function does not exist) and `schedule/2` returns `{:error, :hidden}`.
  """
  alias Annuart.Chain.Abi

  @spec schedule(String.t(), integer) ::
          {:ok, [%{duration: integer, rate_per_sec: integer}]} | {:error, :hidden | term}
  def schedule(nft, id) do
    case read(nft, :schedule_of, [id]) do
      {:error, {:revert, _}} -> {:error, :hidden}
      other -> other
    end
  end

  @spec last_accrual_at(String.t(), integer) :: {:ok, integer} | {:error, term}
  def last_accrual_at(nft, id), do: read(nft, :last_accrual_at_of, [id])

  @spec schedule_end(String.t(), integer) :: {:ok, integer} | {:error, term}
  def schedule_end(nft, id), do: read(nft, :schedule_end_of, [id])

  @spec settled(String.t(), integer) :: {:ok, boolean} | {:error, term}
  def settled(nft, id), do: read(nft, :settled_of, [id])

  @spec token_meta(String.t()) :: {:ok, %{symbol: String.t(), decimals: integer}} | {:error, term}
  def token_meta(token) do
    with {:ok, symbol} <- read(token, :symbol, []),
         {:ok, decimals} <- read(token, :decimals, []) do
      {:ok, %{symbol: symbol, decimals: decimals}}
    end
  end

  defp read(to, fun, args) do
    with {:ok, hex} <- rpc().eth_call(to, Abi.encode_call(fun, args)) do
      decode(fun, hex)
    end
  end

  # Empty return data means no such function (or no contract) at the address.
  defp decode(_fun, hex) when hex in ["0x", ""], do: {:error, {:revert, "0x"}}

  defp decode(fun, hex) do
    {:ok, Abi.decode_result(fun, hex)}
  rescue
    _ -> {:error, {:bad_result, hex}}
  end

  defp rpc, do: Application.get_env(:annuart, :rpc, Annuart.Chain.Rpc)
end
