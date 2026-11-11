defmodule Annuart.Enfts.Name do
  @moduledoc """
  An ENFT's optional public name, as `EndowmentNFT` stores it: up to 31 ASCII
  characters in a zero-padded `bytes32`. The contract only accepts letters,
  digits, space and `- _ . '`, with no space at either end; the same rule is
  applied again here, so a name that reaches a page is always plain text even
  if a contract at a configured address does not enforce it.
  """

  @max 31
  @pattern ~r/\A[A-Za-z0-9 \-_.']+\z/

  @doc "Longest name, in characters."
  def max, do: @max

  @doc "The name in a 32-byte word, or `nil` when the word is zero or not a valid name."
  @spec from_bytes32(binary) :: String.t() | nil
  def from_bytes32(<<_::binary-size(32)>> = word) do
    name = String.trim_trailing(word, <<0>>)
    if valid?(name), do: name
  end

  def from_bytes32(_), do: nil

  @doc "Whether `name` is one the contract accepts (the empty string is not a name)."
  @spec valid?(term) :: boolean
  def valid?(name) when is_binary(name) do
    byte_size(name) in 1..@max and Regex.match?(@pattern, name) and
      not String.starts_with?(name, " ") and not String.ends_with?(name, " ")
  end

  def valid?(_), do: false
end
