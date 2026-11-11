defmodule Annuart.RandomartTest do
  use ExUnit.Case, async: true
  alias Annuart.Randomart

  # The worked example of "The drunken bishop: An analysis of the OpenSSH
  # fingerprint visualization algorithm" (Loss, Limmer, von Gernler, 2009).
  test "draws OpenSSH's picture for a known fingerprint" do
    fingerprint = Base.decode16!("FC94B0C1E5B0987C5843997697EE9FB7")

    assert Randomart.ascii(fingerprint) ==
             Enum.join(
               [
                 "       .=o.  .   ",
                 "     . *+*. o    ",
                 "      =.*..o     ",
                 "       o + ..    ",
                 "        S o.     ",
                 "         o  .    ",
                 "          .  . . ",
                 "              o .",
                 "               E."
               ],
               "\n"
             )
  end

  test "an address gives the same picture however its hex is cased" do
    lower = "0x70997970c51812dc3a010c7d01b50e0d17dc79c8"

    assert Randomart.cells(lower) ==
             Randomart.cells(String.upcase(lower, :ascii) |> String.replace("0X", "0x"))

    assert Randomart.cells(lower) != Randomart.cells("0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266")
  end

  test "marks one start and one end, inside the board" do
    cells = Randomart.cells("0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266")
    assert Enum.count(cells, &(&1.mark == :end)) == 1
    assert Enum.count(cells, &(&1.mark == :start)) <= 1
    assert Enum.all?(cells, &(&1.x in 0..16 and &1.y in 0..8))
  end

  test "no bytes leaves the bishop on the start square" do
    assert Randomart.cells("0x") == [%{x: 8, y: 4, visits: 0, mark: :end}]
  end

  test "text that is not hex has no picture" do
    assert Randomart.cells("0xnothex") == nil
    assert Randomart.ascii("0xnothex") == nil
  end
end
