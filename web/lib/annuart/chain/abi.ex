defmodule Annuart.Chain.Abi do
  @moduledoc """
  ABI codec for the public contract surface the server reads: event topics,
  log decoding, and the view calls on `EndowmentNFT` and its token. All data
  here is public chain data; nothing secret passes through.
  """

  @topics %{
    endowment_minted: "0x25a622b3341f11db07752ec3231ebbf16da534e766579285f53d6b44d736ac3b",
    transfer: "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef",
    auto_payout_set: "0x8bcf464aca0c3a4f72cb8523a3ceb88ba6f17985819ffd2922e6d3d855e3f479",
    payout_requested: "0xe559d654c6733656f8709e3f8f321f64d19d289bd625bb184161881dea19a4e7",
    payout_paid: "0xe4e624488c455a4960889c1eacc4b1c8399a43ddab47d8151e8044e341790563"
  }

  # fun => {signature, output type}
  @functions %{
    schedule_of: {"scheduleOf(uint256)", "(uint64,uint64)[]"},
    schedule_start_of: {"scheduleStartOf(uint256)", "uint64"},
    schedule_end_of: {"scheduleEndOf(uint256)", "uint64"},
    last_accrual_at_of: {"lastAccrualAtOf(uint256)", "uint64"},
    settled_of: {"settledOf(uint256)", "bool"},
    top_ups_allowed_of: {"topUpsAllowedOf(uint256)", "bool"},
    owner_of: {"ownerOf(uint256)", "address"},
    symbol: {"symbol()", "string"},
    decimals: {"decimals()", "uint8"}
  }

  @spec topic(
          :endowment_minted
          | :transfer
          | :auto_payout_set
          | :payout_requested
          | :payout_paid
        ) :: String.t()
  def topic(name), do: Map.fetch!(@topics, name)

  @doc "Decodes a JSON-RPC log map (string keys `\"topics\"`, `\"data\"`)."
  def decode_log(%{"topics" => [t0 | indexed], "data" => data}) do
    cond do
      t0 == topic(:endowment_minted) and length(indexed) == 3 ->
        [id, creator, to] = indexed
        [start, top_ups, name] = ABI.decode("f(uint64,bool,bytes32)", from_hex(data))

        {:minted,
         %{
           token_id: topic_uint(id),
           creator: topic_address(creator),
           to: topic_address(to),
           schedule_start: start,
           top_ups_allowed: top_ups,
           # nil when unnamed, and when the bytes are not a name the contract accepts.
           name: Annuart.Enfts.Name.from_bytes32(name)
         }}

      t0 == topic(:transfer) and length(indexed) == 3 ->
        [from, to, id] = indexed

        {:transfer, %{from: topic_address(from), to: topic_address(to), token_id: topic_uint(id)}}

      t0 == topic(:auto_payout_set) and length(indexed) == 1 ->
        [id] = indexed
        [enabled, interval, fee] = ABI.decode("f(bool,uint32,uint128)", from_hex(data))

        {:auto_payout_set,
         %{token_id: topic_uint(id), enabled: enabled, interval: interval, fee: fee}}

      t0 == topic(:payout_requested) and length(indexed) == 3 ->
        [id, request_id, recipient] = indexed
        [requester, fee] = ABI.decode("f(address,uint128)", from_hex(data))

        {:payout_requested,
         %{
           token_id: topic_uint(id),
           request_id: String.downcase(request_id),
           recipient: topic_address(recipient),
           requester: to_hex(requester),
           fee: fee
         }}

      t0 == topic(:payout_paid) and length(indexed) == 2 ->
        [id, request_id] = indexed
        [amount, fee, in_weth] = ABI.decode("f(uint256,uint256,bool)", from_hex(data))

        {:payout_paid,
         %{
           token_id: topic_uint(id),
           request_id: String.downcase(request_id),
           amount_wei: amount,
           fee_wei: fee,
           paid_in_weth: in_weth
         }}

      true ->
        :unknown
    end
  end

  def decode_log(_), do: :unknown

  @doc "ABI-encodes a call as 0x-hex. Address arguments may be 0x-hex strings."
  @spec encode_call(atom, list) :: String.t()
  def encode_call(fun, args) do
    {sig, _} = Map.fetch!(@functions, fun)
    "0x" <> Base.encode16(ABI.encode(sig, Enum.map(args, &arg/1)), case: :lower)
  end

  @doc "Decodes a call result: schedule as a segment list, addresses as lowercase 0x-hex."
  @spec decode_result(atom, String.t()) :: term
  def decode_result(fun, hex) do
    {_, output} = Map.fetch!(@functions, fun)
    # A return value is encoded exactly like a single call argument.
    [value] = ABI.decode("result(#{output})", from_hex(hex))
    result(fun, value)
  end

  defp result(:schedule_of, segments),
    do: Enum.map(segments, fn {duration, rate} -> %{duration: duration, rate_per_sec: rate} end)

  defp result(:owner_of, addr), do: to_hex(addr)
  defp result(_, value), do: value

  defp arg("0x" <> _ = addr), do: from_hex(addr)
  defp arg(other), do: other

  defp topic_uint("0x" <> hex), do: String.to_integer(hex, 16)
  defp topic_address("0x" <> hex), do: "0x" <> String.downcase(binary_part(hex, 24, 40))

  defp from_hex("0x" <> hex), do: Base.decode16!(hex, case: :mixed)
  defp to_hex(bin), do: "0x" <> Base.encode16(bin, case: :lower)
end
