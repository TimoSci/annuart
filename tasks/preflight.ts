// Pure decision logic for scripts/preflight.ts: no I/O, so it can be unit-tested.
export const SEPOLIA_FHEVM = {
  acl: "0xf0Ffdc93b7E186bC2f8CB3dAA75D86d1930A433D",
  coprocessor: "0x92C920834Ec8941d2C77D188936E1f7A6f49c127",
  kmsVerifier: "0xbE0E383937d564D7FF0BC3b46c51f0bF8d5C311A",
};
export const MIN_BALANCE_WEI = 50_000_000_000_000_000n; // 0.05 ETH

export type Facts = {
  chainId: number; deployer: string | null; balanceWei: bigint;
  codeAt: Record<string, boolean>;                 // lowercased address -> has code
  sdk: { acl: string; kmsVerifier: string } | null; // from the relayer SDK's SepoliaConfig
  relayerEncryptOk: boolean | null;                // null = not attempted
  weth: { address: string; symbol: string | null; decimals: number | null } | null;
};

const SEPOLIA_CHAIN_ID = 11155111;
const same = (a: string, b: string) => a.toLowerCase() === b.toLowerCase();

export function problems(f: Facts): string[] {
  const out: string[] = [];
  if (f.chainId !== SEPOLIA_CHAIN_ID) {
    out.push(`The RPC is chain id ${f.chainId}, not Sepolia (${SEPOLIA_CHAIN_ID}). Check SEPOLIA_RPC_URL.`);
  }
  if (f.deployer === null) {
    out.push("PRIVATE_KEY is not set, so there is no deployer account.");
  } else if (f.balanceWei === 0n) {
    out.push(`Deployer ${f.deployer} has no Sepolia ETH.`);
  }
  const missing = Object.values(SEPOLIA_FHEVM).filter((a) => !f.codeAt[a.toLowerCase()]);
  if (missing.length > 0) {
    out.push(`Zama's FHE contracts have no code at: ${missing.join(", ")}. The contracts are compiled against addresses that are not live on this network.`);
  }
  if (f.sdk === null) {
    out.push("The encryption library (relayer SDK) has no Sepolia configuration.");
  } else if (!same(f.sdk.acl, SEPOLIA_FHEVM.acl) || !same(f.sdk.kmsVerifier, SEPOLIA_FHEVM.kmsVerifier)) {
    out.push(
      `The encryption library uses different FHE addresses (ACL ${f.sdk.acl}, KMS verifier ${f.sdk.kmsVerifier}) ` +
        `than the contracts are compiled against (ACL ${SEPOLIA_FHEVM.acl}, KMS verifier ${SEPOLIA_FHEVM.kmsVerifier}).`,
    );
  }
  if (f.relayerEncryptOk === false) {
    out.push("Zama's relayer did not accept an encrypted value from this library version.");
  }
  if (f.weth) {
    const hasCode = f.codeAt[f.weth.address.toLowerCase()] === true;
    if (!hasCode || f.weth.symbol !== "WETH" || f.weth.decimals !== 18) {
      out.push(
        `WETH_ADDRESS ${f.weth.address} is not a WETH contract ` +
          `(code: ${hasCode ? "yes" : "no"}, symbol: ${f.weth.symbol ?? "unreadable"}, decimals: ${f.weth.decimals ?? "unreadable"}).`,
      );
    }
  }
  return out;
}

export function warnings(f: Facts): string[] {
  const out: string[] = [];
  if (f.balanceWei > 0n && f.balanceWei < MIN_BALANCE_WEI) {
    out.push("Deployer balance is below 0.05 ETH; deployments may run out of gas money.");
  }
  if (f.relayerEncryptOk === null) {
    out.push("The relayer check was skipped (PREFLIGHT_SKIP_RELAYER=1); encrypted input was not tested.");
  }
  if (f.weth === null) {
    out.push("WETH_ADDRESS is not set; you cannot deploy the wrapped variant (TOKEN_KIND=wrapped) until it is.");
  }
  return out;
}
