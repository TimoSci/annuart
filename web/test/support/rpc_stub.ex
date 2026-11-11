defmodule Annuart.RpcStub do
  @moduledoc """
  Agent-backed stand-in for `Annuart.Chain.Rpc`, selected in `config/test.exs`.
  Started by `test_helper.exs`. Seed canned data with the `put_*` functions; `reset/0` (called by tests in
  `setup`) clears it. Unseeded calls return empty or error results.
  """
  use Agent

  @empty %{logs: [], calls: %{}, blocks: %{}, head: 0, code: %{}}

  def start_link(_ \\ []), do: Agent.start_link(fn -> @empty end, name: __MODULE__)

  defp update(fun) do
    Agent.update(__MODULE__, fun)
  end

  defp get(fun) do
    Agent.get(__MODULE__, fun)
  end

  def reset, do: update(fn _ -> @empty end)

  @doc "Logs returned by `get_logs/1` (filtered by block range and first topic)."
  def put_logs(logs), do: update(&Map.put(&1, :logs, logs))
  @doc "Canned `eth_call` result for `{to, data}`: `{:ok, hex}` or `{:error, term}`."
  def put_call(to, data, result),
    do: update(&put_in(&1.calls[{String.downcase(to), data}], result))

  def put_block(number, %{hash: _, timestamp: _} = block),
    do: update(&put_in(&1.blocks[number], block))

  def put_head(number), do: update(&Map.put(&1, :head, number))
  def put_code(address, code), do: update(&put_in(&1.code[String.downcase(address)], code))

  def block_number, do: {:ok, get(& &1.head)}

  def block(number) do
    case get(&Map.get(&1.blocks, number)) do
      nil -> {:error, :not_found}
      block -> {:ok, block}
    end
  end

  def get_logs(%{from_block: from, to_block: to} = filter) do
    address = filter |> Map.get(:address) |> List.wrap() |> Enum.map(&String.downcase/1)

    logs =
      get(& &1.logs)
      |> Enum.filter(fn log ->
        n = block_of(log)

        n >= from and n <= to and
          (address == [] or String.downcase(log["address"] || "") in address) and
          topic0_match?(log, filter[:topics])
      end)

    {:ok, logs}
  end

  def eth_call(to, data) do
    case get(&Map.fetch(&1.calls, {String.downcase(to), data})) do
      {:ok, result} -> result
      :error -> {:error, {:revert, "0x"}}
    end
  end

  def get_code(address), do: {:ok, get(&Map.get(&1.code, String.downcase(address), "0x"))}

  defp block_of(%{"blockNumber" => "0x" <> hex}), do: String.to_integer(hex, 16)
  defp block_of(%{"blockNumber" => n}) when is_integer(n), do: n
  defp block_of(_), do: 0

  defp topic0_match?(_log, [t | _]) when t in [nil, []], do: true
  defp topic0_match?(%{"topics" => [t0 | _]}, [want | _]), do: t0 in List.wrap(want)
  defp topic0_match?(_, _), do: true
end
