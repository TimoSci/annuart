// DEV BUNDLE ONLY. Derives Hardhat's well-known test accounts from its public
// mnemonic. Never import this from app.js: it must not reach production.
import {HDNodeWallet, JsonRpcProvider} from "ethers";
import {chainInfo} from "../signer.js";
import {DEV_CHAIN} from "../chains.js";

const MNEMONIC = "test test test test test test test test test test test junk";
const refuse = () => new Error(`dev login is only available on chain ${DEV_CHAIN}`);

const wallet = index => HDNodeWallet.fromPhrase(MNEMONIC, undefined, `m/44'/60'/0'/0/${index}`);

export const accounts = [0, 1, 2, 3, 4].map(i => wallet(i).address);

// `provider` is a test seam; in the browser it is always a JsonRpcProvider.
export async function createDevSigner({index, provider} = {}) {
  if (!Number.isInteger(index) || index < 0 || index > 4) throw new Error("dev account index must be 0 to 4");
  const info = chainInfo();
  if (info.chainId !== DEV_CHAIN) throw refuse();
  // cacheTimeout -1: without it ethers caches nonces and Hardhat answers "nonce too low".
  provider ??= new JsonRpcProvider(info.rpcUrl, undefined, {cacheTimeout: -1});
  const network = await provider.getNetwork();
  if (Number(network.chainId) !== DEV_CHAIN) throw refuse();
  const signer = wallet(index).connect(provider);
  return {kind: "dev", address: signer.address, signer, provider, chainId: DEV_CHAIN};
}
