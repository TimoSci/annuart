defmodule Annuart.Chain.ConfigTest do
  # Not async: some tests change application env.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

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

  test "two contracts with the same label are invalid", %{dir: dir} do
    entry = fn nft ->
      ~s({"label":"mock","nft":"#{nft}","token":"0x02","tokenKind":"mock","underlying":null,"deployBlock":1})
    end

    path = write_tmp!(dir, ~s({"chainId":1,"contracts":[#{entry.("0x01")},#{entry.("0x03")}]}))
    assert {:error, :invalid} = Config.load(path)
  end

  test "a contract missing a field is invalid", %{dir: dir} do
    path = write_tmp!(dir, ~s({"chainId":1,"contracts":[{"label":"x"}]}))
    assert {:error, :invalid} = Config.load(path)
  end

  describe "init/0" do
    setup do
      previous =
        for k <- [:chain, :deployments_path, :rpc_url],
            do: {k, Application.fetch_env(:annuart, k)}

      Application.delete_env(:annuart, :chain)

      on_exit(fn ->
        for {k, v} <- previous do
          case v do
            {:ok, val} -> Application.put_env(:annuart, k, val)
            :error -> Application.delete_env(:annuart, k)
          end
        end
      end)
    end

    test "a missing file yields no contracts, chain id 0 and a warning" do
      Application.put_env(:annuart, :deployments_path, "/nonexistent.json")
      Application.put_env(:annuart, :rpc_url, "http://rpc.test")

      log = capture_log(fn -> assert :ok = Config.init() end)

      assert log =~ "could not load deployments"
      assert Config.contracts() == []
      assert Config.chain_id() == 0
      assert Config.rpc_url() == "http://rpc.test"
    end

    test "a valid file yields its contracts", %{dir: dir} do
      Application.put_env(:annuart, :deployments_path, write_tmp!(dir, deployment("mock")))
      Application.put_env(:annuart, :rpc_url, "http://rpc.test")

      assert capture_log(fn -> Config.init() end) == ""
      assert Config.chain_id() == 31337
      assert [%Config.Contract{label: "mock"}] = Config.contracts()
      assert Config.contract("mock").deploy_block == 8
    end

    test "chain_id is 0 when nothing is configured" do
      assert Config.chain_id() == 0
      assert Config.contracts() == []
    end
  end
end
