import { ethers, network } from "hardhat";
import { MIN_BALANCE_WEI, SEPOLIA_FHEVM, problems, warnings, type Facts } from "../tasks/preflight";

// Reads facts about a public network and the encryption library, prints one line per
// check, and exits non-zero if anything would make a deploy unusable. Sends no transaction.
//
//   PREFLIGHT_SKIP_RELAYER=1   skip the relayer encryption check
//   WETH_ADDRESS               optional; checked to be a WETH contract
const TIMEOUT_MS = 120_000;

async function relayerCheck(sdk: any, rpcUrl: string, target: string, user: string): Promise<boolean> {
  let timer: NodeJS.Timeout | undefined;
  try {
    const run = (async () => {
      const instance = await sdk.createInstance({ ...sdk.SepoliaConfig, network: rpcUrl });
      await instance.createEncryptedInput(target, user).add64(1n).encrypt();
    })();
    const timeout = new Promise<never>((_, reject) => {
      timer = setTimeout(() => reject(new Error(`timed out after ${TIMEOUT_MS / 1000}s`)), TIMEOUT_MS);
    });
    await Promise.race([run, timeout]);
    return true;
  } catch (e) {
    console.log(`  relayer error: ${e instanceof Error ? e.message : e}`);
    return false;
  } finally {
    if (timer) clearTimeout(timer);
  }
}

async function main() {
  if (network.name === "localhost" || network.name === "hardhat") {
    throw new Error("Pre-flight is for public networks; run it with --network sepolia");
  }
  const rpcUrl = process.env.SEPOLIA_RPC_URL;
  if (!rpcUrl) throw new Error("SEPOLIA_RPC_URL is not set; export it in your shell (see .env.example)");

  let chainId: number;
  try {
    chainId = Number((await ethers.provider.getNetwork()).chainId);
  } catch (e) {
    throw new Error(`Cannot reach the RPC at SEPOLIA_RPC_URL: ${e instanceof Error ? e.message : e}`);
  }
  console.log(`Network:   ${network.name} (chain id ${chainId})`);

  const [signer] = await ethers.getSigners();
  const deployer = signer ? signer.address : null;
  const balanceWei = deployer ? await ethers.provider.getBalance(deployer) : 0n;
  console.log(`Deployer:  ${deployer ?? "none (PRIVATE_KEY is not set)"}`);
  console.log(`Balance:   ${ethers.formatEther(balanceWei)} ETH (warn below ${ethers.formatEther(MIN_BALANCE_WEI)})`);

  const wethAddress = process.env.WETH_ADDRESS || null;
  const addresses = [...Object.values(SEPOLIA_FHEVM), ...(wethAddress ? [wethAddress] : [])];
  const codeAt: Record<string, boolean> = {};
  for (const a of addresses) {
    codeAt[a.toLowerCase()] = (await ethers.provider.getCode(a)) !== "0x";
  }
  for (const [name, a] of Object.entries(SEPOLIA_FHEVM)) {
    console.log(`FHE ${name}: ${a} ${codeAt[a.toLowerCase()] ? "has code" : "NO CODE"}`);
  }

  let weth: Facts["weth"] = null;
  if (wethAddress) {
    const c = new ethers.Contract(
      wethAddress,
      ["function symbol() view returns (string)", "function decimals() view returns (uint8)"],
      ethers.provider,
    );
    const symbol = await c.symbol().then(String, () => null);
    const decimals = await c.decimals().then(Number, () => null);
    weth = { address: wethAddress, symbol, decimals };
    console.log(`WETH:      ${wethAddress} symbol ${symbol ?? "unreadable"}, decimals ${decimals ?? "unreadable"}`);
  } else {
    console.log("WETH:      WETH_ADDRESS not set");
  }

  // The package ships a CommonJS entry, so a static import resolves under ts-node.
  const sdk = await import("@zama-fhe/relayer-sdk/node");
  const cfg: any = sdk.SepoliaConfig;
  const sdkFacts = cfg ? { acl: String(cfg.aclContractAddress), kmsVerifier: String(cfg.kmsContractAddress) } : null;
  console.log(`SDK:       ACL ${sdkFacts?.acl ?? "missing"}, KMS verifier ${sdkFacts?.kmsVerifier ?? "missing"}`);

  let relayerEncryptOk: boolean | null = null;
  if (process.env.PREFLIGHT_SKIP_RELAYER === "1") {
    console.log("Relayer:   skipped");
  } else if (deployer === null) {
    console.log("Relayer:   skipped (no deployer address to encrypt for)");
  } else {
    console.log("Relayer:   encrypting a test value (up to 120s)...");
    relayerEncryptOk = await relayerCheck(sdk, rpcUrl, wethAddress ?? SEPOLIA_FHEVM.acl, deployer);
    console.log(`Relayer:   ${relayerEncryptOk ? "accepted the encrypted value" : "FAILED"}`);
  }

  const facts: Facts = { chainId, deployer, balanceWei, codeAt, sdk: sdkFacts, relayerEncryptOk, weth };
  for (const w of warnings(facts)) console.log(`Warning: ${w}`);
  const found = problems(facts);
  if (found.length === 0) {
    console.log("Pre-flight passed");
  } else {
    console.error("Pre-flight FAILED:");
    for (const p of found) console.error(`  - ${p}`);
    process.exitCode = 1;
  }
}

main().catch((e) => {
  console.error(e instanceof Error ? e.message : e);
  process.exitCode = 1;
});
