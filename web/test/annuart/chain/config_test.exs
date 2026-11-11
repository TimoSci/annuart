defmodule Annuart.Chain.ConfigTest do
  use ExUnit.Case, async: true

  alias Annuart.Chain.Config

  @moduletag :tmp_dir

  setup %{tmp_dir: dir}, do: %{dir: dir}

  defp write_tmp!(dir, contents) do
    path = Path.join(dir, "deployment-#{System.unique_integer([:positive])}.json")
    File.write!(path, contents)
    path
  end

  defp deployment(token_kind) do
    ~s({"chainId":31337,"contracts":[{"label":"mock","nft":"0xAbC0000000000000000000000000000000000001","token":"0x0000000000000000000000000000000000000002","tokenKind":"#{token_kind}","underlying":null,"deployBlock":8}]})
  end

  test "loads the deployment file shape", %{dir: dir} do
    path = write_tmp!(dir, deployment("mock"))

    assert {:ok, %{chain_id: 31337, contracts: [c]}} = Config.load(path)
    assert %Config.Contract{} = c
    assert c.label == "mock" and c.token_kind == :mock and c.deploy_block == 8
    assert c.nft == "0xabc0000000000000000000000000000000000001"
    assert c.token == "0x0000000000000000000000000000000000000002"
    assert c.underlying == nil
  end

  test "lowercases the underlying address of a wrapped token", %{dir: dir} do
    path =
      write_tmp!(
        dir,
        ~s({"chainId":1,"contracts":[{"label":"w","nft":"0xAA","token":"0xBB","tokenKind":"wrapped","underlying":"0xCC","deployBlock":1}]})
      )

    assert {:ok, %{contracts: [%{token_kind: :wrapped, underlying: "0xcc"}]}} = Config.load(path)
  end

  test "missing file" do
    assert {:error, :enoent} = Config.load("/nonexistent.json")
  end

  test "malformed file", %{dir: dir} do
    assert {:error, :invalid} = Config.load(write_tmp!(dir, "{"))
  end

  test "unknown tokenKind is invalid", %{dir: dir} do
    assert {:error, :invalid} = Config.load(write_tmp!(dir, deployment("weird")))
  end

  test "a contract missing a field is invalid", %{dir: dir} do
    path = write_tmp!(dir, ~s({"chainId":1,"contracts":[{"label":"x"}]}))
    assert {:error, :invalid} = Config.load(path)
  end
end
