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

  describe "what the page publishes" do
    @env_keys [:chain, :public_rpc_url, :indexer_confirmations, :indexer_chunk]

    setup do
      previous = for k <- @env_keys, do: {k, Application.fetch_env(:annuart, k)}

      for k <- [:public_rpc_url, :indexer_confirmations, :indexer_chunk],
          do: Application.delete_env(:annuart, k)

      on_exit(fn ->
        for {k, v} <- previous do
          case v do
            {:ok, val} -> Application.put_env(:annuart, k, val)
            :error -> Application.delete_env(:annuart, k)
          end
        end
      end)
    end

    defp put_chain(opts) do
      Application.put_env(
        :annuart,
        :chain,
        Keyword.merge([rpc_url: "http://127.0.0.1:8545", contracts: []], opts)
      )
    end

    test "public/0 hides the server RPC URL off the local chain" do
      put_chain(chain_id: 11_155_111, rpc_url: "https://rpc.example/v3/SECRET", contracts: [])
      assert Config.public().rpcUrl == nil
      refute Jason.encode!(Config.public()) =~ "SECRET"
    end

    test "public/0 publishes the RPC URL on chain 31337" do
      put_chain(chain_id: 31_337, rpc_url: "http://127.0.0.1:8545", contracts: [])
      assert Config.public().rpcUrl == "http://127.0.0.1:8545"
    end

    test "public/0 prefers an explicit public RPC URL" do
      put_chain(chain_id: 11_155_111, rpc_url: "https://rpc.example/v3/SECRET", contracts: [])
      Application.put_env(:annuart, :public_rpc_url, "https://public.example")
      assert Config.public().rpcUrl == "https://public.example"
    end

    test "a blank public RPC URL counts as unset" do
      put_chain(chain_id: 11_155_111, rpc_url: "https://rpc.example/v3/SECRET", contracts: [])
      Application.put_env(:annuart, :public_rpc_url, "  ")
      assert Config.public_rpc_url() == nil
      assert Config.public().rpcUrl == nil
    end

    test "confirmations default to 0 locally and 2 elsewhere, and can be set" do
      put_chain(chain_id: 31_337, contracts: [])
      assert Config.confirmations() == 0
      put_chain(chain_id: 0, contracts: [])
      assert Config.confirmations() == 0
      put_chain(chain_id: 11_155_111, contracts: [])
      assert Config.confirmations() == 2
      Application.put_env(:annuart, :indexer_confirmations, 5)
      assert Config.confirmations() == 5
      assert Config.index_wait_ms() == 95_000
    end

    test "a bad confirmations setting falls back to the default" do
      put_chain(chain_id: 11_155_111, contracts: [])
      Application.put_env(:annuart, :indexer_confirmations, -1)
      assert Config.confirmations() == 2
      Application.put_env(:annuart, :indexer_confirmations, "3")
      assert Config.confirmations() == 2
    end

    test "log_chunk defaults to 2000 and can be set" do
      assert Config.log_chunk() == 2_000
      Application.put_env(:annuart, :indexer_chunk, 10)
      assert Config.log_chunk() == 10
    end
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
