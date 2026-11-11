// Spike: the FHEVM mock (@fhevm/mock-utils MockFhevmInstance) running in a browser
// against a local `npx hardhat node`. Throwaway code; see web/docs/fhe-browser-spike.md.
//
// Bundled by esbuild with `@zama-fhe/relayer-sdk/node` aliased to `@zama-fhe/relayer-sdk/web`
// (mock-utils imports the node entry for KmsEIP712 and TKMSPkeKeypair).
import { Contract, HDNodeWallet, JsonRpcProvider } from "ethers";
import { MockFhevmInstance, contracts, relayer } from "@fhevm/mock-utils";
import { initSDK } from "@zama-fhe/relayer-sdk/web";
import deployments from "../../deployments/localhost.json";

const RPC_URL = "http://127.0.0.1:8545";
const MNEMONIC = "test test test test test test test test test test test junk";

const TOKEN_ABI = [
  "function mint(address to, uint64 amount)",
  "function setOperator(address operator, uint48 until)",
];
const NFT_ABI = [
  "function mint(address to, bytes32 encEndowment, bytes inputProof, (uint64 duration, uint64 ratePerSec)[] segments, uint64 scheduleStart, bool topUpsAllowed) returns (uint256)",
  "function accrue(uint256 tokenId)",
  "function scheduleStartOf(uint256 tokenId) view returns (uint64)",
  "function distributionHandle(uint256 tokenId) view returns (bytes32)",
  "event Transfer(address indexed from, address indexed to, uint256 indexed tokenId)",
];

// Builds a MockFhevmInstance from what the chain itself reports: the Hardhat node's
// `fhevm_relayer_metadata` RPC gives the host contract addresses, and the
// InputVerifier / KMSVerifier contracts' EIP-712 domains give the gateway chain id and
// the gateway verifying contracts (this is what @fhevm/hardhat-plugin does in-process).
export async function createMockInstance(provider) {
  const metadata = await relayer.requestRelayerMetadata(provider);
  const inputVerifier = await contracts.InputVerifier.create(provider, metadata.InputVerifierAddress);
  const kmsVerifier = await contracts.KMSVerifier.create(provider, metadata.KMSVerifierAddress);
  const instance = await MockFhevmInstance.create(
    provider,
    provider,
    {
      verifyingContractAddressDecryption: kmsVerifier.gatewayDecryptionAddress,
      verifyingContractAddressInputVerification: inputVerifier.gatewayInputVerificationAddress,
      kmsContractAddress: metadata.KMSVerifierAddress,
      inputVerifierContractAddress: metadata.InputVerifierAddress,
      aclContractAddress: metadata.ACLAddress,
      chainId: metadata.chainId,
      gatewayChainId: Number(kmsVerifier.gatewayChainId),
    },
    {
      inputVerifierProperties: inputVerifier.inputVerifierProperties,
      kmsVerifierProperties: kmsVerifier.kmsVerifierProperties,
    },
  );
  return { instance, metadata };
}

async function run() {
  // cacheTimeout -1: ethers caches identical RPC results for 250 ms by default, so back-to-back
  // transactions on an automining node reuse a stale eth_getTransactionCount ("nonce too low").
  const provider = new JsonRpcProvider(RPC_URL, undefined, { pollingInterval: 100, cacheTimeout: -1 });
  const wallet = HDNodeWallet.fromPhrase(MNEMONIC).connect(provider);
  const dep = deployments.contracts.find((c) => c.label === "mock");
  if (!dep) throw new Error("no 'mock' entry in deployments/localhost.json");

  // MockFhevmInstance.generateKeypair() needs the TKMS WASM from the relayer SDK.
  await initSDK();
  const { instance } = await createMockInstance(provider);

  const token = new Contract(dep.token, TOKEN_ABI, wallet);
  const nft = new Contract(dep.nft, NFT_ABI, wallet);

  await (await token.mint(wallet.address, 500)).wait();
  const until = Math.floor(Date.now() / 1000) + 365 * 24 * 3600;
  await (await token.setOperator(dep.nft, until)).wait();

  const enc = await instance.createEncryptedInput(dep.nft, wallet.address).add64(500).encrypt();
  const mintRcpt = await (
    await nft.mint(wallet.address, enc.handles[0], enc.inputProof, [{ duration: 1000, ratePerSec: 1 }], 0, false)
  ).wait();
  const transfer = mintRcpt.logs
    .map((l) => {
      try {
        return nft.interface.parseLog(l);
      } catch {
        return null;
      }
    })
    .find((e) => e?.name === "Transfer");
  const mintedTokenId = transfer.args.tokenId.toString();

  await provider.send("evm_increaseTime", [100]);
  const accrueRcpt = await (await nft.accrue(mintedTokenId)).wait();
  const accrueTs = BigInt((await provider.getBlock(accrueRcpt.blockNumber)).timestamp);
  const start = await nft.scheduleStartOf(mintedTokenId);
  const owed = accrueTs - start;
  const expectedDistribution = (owed < 500n ? owed : 500n).toString();

  const handle = await nft.distributionHandle(mintedTokenId);
  const { publicKey, privateKey } = instance.generateKeypair();
  const startTimestamp = Math.floor(Date.now() / 1000);
  const durationDays = 1;
  const eip712 = instance.createEIP712(publicKey, [dep.nft], startTimestamp, durationDays);
  const signature = await wallet.signTypedData(
    eip712.domain,
    { [eip712.primaryType]: eip712.types[eip712.primaryType] },
    eip712.message,
  );
  const clear = await instance.userDecrypt(
    [{ handle, contractAddress: dep.nft }],
    privateKey,
    publicKey,
    signature,
    [dep.nft],
    wallet.address,
    startTimestamp,
    durationDays,
  );

  return { mintedTokenId, decryptedDistribution: clear[handle].toString(), expectedDistribution };
}

run().then(
  (r) => {
    window.__spike = { done: true, ...r };
  },
  (e) => {
    console.error(e);
    window.__spike = { done: true, error: String(e?.stack || e) };
  },
);
