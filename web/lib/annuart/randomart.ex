defmodule Annuart.Randomart do
  @moduledoc """
  The "drunken bishop" picture OpenSSH draws for a key fingerprint, here drawn
  for an address. A bishop starts in the middle of a 17 by 9 board and makes
  four diagonal moves per byte (two bits each, lowest pair first), sliding
  along the walls; each square counts its visits. The same bytes always give
  the same picture and different bytes almost always a visibly different one,
  so a creator can be recognised at a glance without reading 40 hex digits.

  It is a recognition aid, not a proof: a determined attacker can search for
  an address whose picture looks alike. The full address is the identity.
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
