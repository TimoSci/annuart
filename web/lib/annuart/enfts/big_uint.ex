defmodule Annuart.Enfts.BigUint do
  @moduledoc """
  A non-negative integer up to 2^256 - 1 (a wei amount), stored as decimal text
  because SQLite integers are signed 64-bit.
  """
  use Ecto.Type

  @max Bitwise.bsl(1, 256) - 1

  def type, do: :string

  def cast(n) when is_integer(n) and n >= 0 and n <= @max, do: {:ok, n}
  def cast(_), do: :error

  def dump(n) when is_integer(n) and n >= 0 and n <= @max, do: {:ok, Integer.to_string(n)}
  def dump(_), do: :error

  def load(s) when is_binary(s) do
    case Integer.parse(s) do
      {n, ""} when n >= 0 and n <= @max -> {:ok, n}
      _ -> :error
    end
  end

  def load(_), do: :error
end
