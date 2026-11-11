// DEV BUNDLE ONLY. The FHEVM mock (@fhevm/mock-utils) against a local Hardhat
// node: "encryption" sends the cleartext to the node, which keeps it. Never
// import this from app.js. Construction follows web/docs/fhe-browser-spike.md:
// every address and verifier property is read from the chain itself.
import {JsonRpcProvider} from "ethers";
import {MockFhevmInstance, contracts, relayer} from "@fhevm/mock-utils";
import {chainInfo} from "../signer.js";
import {fheFromInstance} from "../fhe.js";
import {DEV_CHAIN} from "../chains.js";

const refuse = () => new Error(`the mock FHE client is only available on chain ${DEV_CHAIN}`);

// `initWasm` loads the TKMS WASM that generateKeypair() needs (the browser
// passes the relayer SDK's initSDK; Node's entry loads it by itself).
// `provider` is a test seam. It must be a JSON-RPC provider for the node: the
// mock talks to the node's fhevm_relayer_* methods, which a wallet would not relay.
export async function createMockFhe(session, {provider, initWasm} = {}) {
  const info = chainInfo();
  if (session?.chainId !== DEV_CHAIN || info.chainId !== DEV_CHAIN) throw refuse();
  provider ??= new JsonRpcProvider(info.rpcUrl, undefined, {cacheTimeout: -1});
  if (Number((await provider.getNetwork()).chainId) !== DEV_CHAIN) throw refuse();
  await initWasm?.();

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
  return fheFromInstance(instance);
}
