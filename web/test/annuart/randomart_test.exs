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

  describe "enft_cells/2" do
    @nft "0x" <> String.duplicate("a1", 20)

    test "every ENFT has its own picture, whoever created it" do
      one = Randomart.enft_cells(@nft, 1)
      assert is_list(one) and one != []
      assert Randomart.enft_cells(@nft, 1) == one
      assert Randomart.enft_cells(String.upcase(@nft) |> String.replace("0X", "0x"), 1) == one
      refute Randomart.enft_cells(@nft, 2) == one
      refute Randomart.enft_cells("0x" <> String.duplicate("a2", 20), 1) == one
    end

    test "is nil for a contract that is not hex, or an id that is not a number" do
      assert Randomart.enft_cells("nonsense", 1) == nil
      assert Randomart.enft_cells("0xzz", 1) == nil
      assert Randomart.enft_cells(@nft, "1") == nil
      assert Randomart.enft_cells(@nft, -1) == nil
    end
  end

  describe "frame/1" do
    @account "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"
    # The same string assets/js/frame.js gives (assets/test/frame.test.js).
    @frame "conic-gradient(hsl(359 45% 64%) 0% 10%, hsl(17 45% 48%) 10% 20%, hsl(323 45% 48%) 20% 30%, " <>
             "hsl(323 45% 56%) 30% 40%, hsl(17 45% 56%) 40% 50%, hsl(323 45% 40%) 50% 60%, hsl(305 45% 56%) 60% 70%, " <>
             "hsl(323 45% 64%) 70% 80%, hsl(305 45% 48%) 80% 90%, hsl(17 45% 56%) 90% 100%)"

    test "is ten muted segments from the address, the same as the browser's" do
      assert Randomart.frame(@account) == @frame
      assert Randomart.frame(String.downcase(@account)) == @frame
      refute Randomart.frame("0x70997970C51812dc3A010C7d01b50e0d17dc79C8") == @frame
    end

    test "is nil for anything that is not an address" do
      for bad <- [nil, "", "0x1234", @account <> "00", "0x" <> String.duplicate("zz", 20), 5],
          do: assert(Randomart.frame(bad) == nil)
    end
  end
end
