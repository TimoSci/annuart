defmodule Annuart.Randomart do
  @moduledoc """
  Pictures to recognise things by. An ENFT gets the "drunken bishop" picture
  OpenSSH draws for a key fingerprint (`enft_cells/2`); an account gets a frame
  of coloured segments (`frame/1`), drawn around its ENFTs' pictures and around
  its address wherever that is shown.

  The picture: A bishop starts in the middle of a 17 by 9 board and makes
  four diagonal moves per byte (two bits each, lowest pair first), sliding
  along the walls; each square counts its visits. The same bytes always give
  the same picture and different bytes almost always a visibly different one,
  so an ENFT or an account can be recognised at a glance without reading 40
  hex digits.

  Both are recognition aids, not proofs: a determined attacker can search for
  an address whose frame or picture looks alike. The full address is the identity.
  """

  @width 17
  @height 9
  @start {8, 4}
  # OpenSSH's symbols by visit count; S and E mark the start and the end.
  @symbols ~c" .o+=*BOX@%&#/^"

  @type cell :: %{
          x: non_neg_integer,
          y: non_neg_integer,
          visits: pos_integer,
          mark: nil | :start | :end
        }

  def width, do: @width
  def height, do: @height

  @doc """
  The visited squares for `data` (bytes, or a `0x` hex string such as an
  address), as `%{x, y, visits, mark}`. Unvisited squares are left out.
  `nil` when `data` is not hex.
  """
  @spec cells(binary) :: [cell] | nil
  def cells(data) do
    with {:ok, bytes} <- bytes(data) do
      {visits, last} = walk(bytes)

      visits
      |> Map.merge(%{@start => Map.get(visits, @start, 0), last => Map.get(visits, last, 0)})
      |> Enum.map(fn {{x, y} = at, n} -> %{x: x, y: y, visits: n, mark: mark(at, last)} end)
      |> Enum.sort_by(&{&1.y, &1.x})
    else
      :error -> nil
    end
  end

  @doc """
  The picture of one ENFT: `cells/1` of a digest of its contract address and
  token id, so every ENFT has its own. `nil` when `nft` is not a hex address.
  """
  @spec enft_cells(binary, non_neg_integer) :: [cell] | nil
  def enft_cells(nft, token_id) when is_integer(token_id) and token_id >= 0 do
    with {:ok, contract} <- bytes(nft),
         true <- String.starts_with?(nft, "0x") do
      <<seed::binary-size(20), _::binary>> =
        :crypto.hash(:sha256, contract <> <<token_id::unsigned-size(256)>>)

      cells(seed)
    else
      _ -> nil
    end
  end

  def enft_cells(_, _), do: nil

  @frame_segments 10

  @doc """
  The frame of an account, as a CSS `conic-gradient` of ten hard-edged segments
  in one muted colour family. The address's first byte picks the family's hue;
  each pair of its 20 bytes then gives one segment a small step away from that
  hue (first byte) and its lightness (second byte). `assets/js/frame.js`
  computes the same string in the browser. `nil` unless `address` is 20 bytes
  of `0x` hex.
  """
  @spec frame(term) :: String.t() | nil
  def frame("0x" <> hex) when byte_size(hex) == 40 do
    case Base.decode16(hex, case: :mixed) do
      {:ok, <<first, _::binary>> = bytes} ->
        base = div(first * 360, 256)

        stops =
          for {<<step, light>>, i} <-
                Enum.with_index(for(<<pair::binary-size(2) <- bytes>>, do: pair)) do
            hue = Integer.mod(base + (rem(step, 5) - 2) * 18, 360)
            from = div(i * 100, @frame_segments)
            to = div((i + 1) * 100, @frame_segments)
            "hsl(#{hue} 45% #{40 + rem(light, 4) * 8}%) #{from}% #{to}%"
          end

        "conic-gradient(" <> Enum.join(stops, ", ") <> ")"

      :error ->
        nil
    end
  end

  def frame(_), do: nil

  @doc "The picture as OpenSSH prints it, without the frame: nine lines of 17 characters."
  @spec ascii(binary) :: String.t() | nil
  def ascii(data) do
    with cells when is_list(cells) <- cells(data) do
      by_square = Map.new(cells, &{{&1.x, &1.y}, &1})

      Enum.map_join(0..(@height - 1), "\n", fn y ->
        for x <- 0..(@width - 1), into: "" do
          <<symbol(by_square[{x, y}])>>
        end
      end)
    end
  end

  defp symbol(nil), do: ?\s
  defp symbol(%{mark: :start}), do: ?S
  defp symbol(%{mark: :end}), do: ?E
  defp symbol(%{visits: n}), do: Enum.at(@symbols, min(n, length(@symbols) - 1))

  # The end wins when the bishop finishes where it started, as in OpenSSH.
  defp mark(at, last) when at == last, do: :end
  defp mark(at, _last) when at == @start, do: :start
  defp mark(_at, _last), do: nil

  defp walk(bytes) do
    moves =
      for <<byte <- bytes>>, shift <- [0, 2, 4, 6], do: Bitwise.band(Bitwise.bsr(byte, shift), 3)

    Enum.reduce(moves, {%{}, @start}, fn move, {visits, {x, y}} ->
      dx = if Bitwise.band(move, 1) == 1, do: 1, else: -1
      dy = if Bitwise.band(move, 2) == 2, do: 1, else: -1
      at = {clamp(x + dx, @width), clamp(y + dy, @height)}
      {Map.update(visits, at, 1, &(&1 + 1)), at}
    end)
  end

  defp clamp(n, size), do: n |> max(0) |> min(size - 1)

  defp bytes("0x" <> hex), do: Base.decode16(hex, case: :mixed)
  defp bytes(data) when is_binary(data), do: {:ok, data}
  defp bytes(_), do: :error
end
