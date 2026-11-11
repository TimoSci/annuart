defmodule Annuart.Enfts.Uint64 do
  @moduledoc "An unsigned 64-bit integer, stored as text because SQLite integers are signed."
  use Ecto.Type

  @max 18_446_744_073_709_551_615

  def type, do: :string

  def cast(n) when is_integer(n) and n >= 0 and n <= @max, do: {:ok, n}
  def cast(_), do: :error

  def dump(n) when is_integer(n) and n >= 0 and n <= @max, do: {:ok, Integer.to_string(n)}
  def dump(_), do: :error

  def load(s) when is_binary(s) do
    case Integer.parse(s) do
      {n, ""} -> {:ok, n}
      _ -> :error
    end
  end

  def load(_), do: :error
end
