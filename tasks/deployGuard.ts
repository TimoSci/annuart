// Pure decision logic for scripts/deploy.ts: no I/O, so it can be unit-tested.
export type GuardInput = {
  network: string; isLocal: boolean; chainId: number; expectedChainId: number | undefined;
  confirm: string | undefined; label: string; existingLabels: string[]; replace: boolean;
};

// Returns the reason to refuse, or null to go ahead. Local networks are never refused.
export function deployRefusal(i: GuardInput): string | null {
  if (i.isLocal) return null;
  if (i.expectedChainId === undefined) {
    return `Network "${i.network}" has no chainId in hardhat.config.ts, so the chain cannot be verified. Add one before deploying.`;
  }
  if (i.chainId !== i.expectedChainId) {
    return `The RPC answered with chain id ${i.chainId}, but network "${i.network}" is configured for chain id ${i.expectedChainId}. Check SEPOLIA_RPC_URL.`;
  }
  if (i.confirm !== i.network) {
    return `Refusing to deploy to the public network "${i.network}" without confirmation. Re-run with CONFIRM_DEPLOY=${i.network}.`;
  }
  if (i.existingLabels.includes(i.label) && !i.replace) {
    return `label "${i.label}" is already deployed on ${i.network} (see deployments/${i.network}.json). Set REPLACE=1 to overwrite it, or choose another name with LABEL=<name>.`;
  }
  return null;
}

// For a reused wrapped token: what the token itself reports as its underlying is the truth.
// `reported` is null when the underlying() call failed.
export function reusedUnderlying(i: { reported: string | null; wethAddress: string | undefined }):
  { underlying: string } | { refusal: string } {
  if (i.reported === null || /^0x0{40}$/i.test(i.reported)) {
    return { refusal: "TOKEN_ADDRESS is not a ConfidentialWETH: its underlying() could not be read or is the zero address." };
  }
  if (i.wethAddress && i.wethAddress.toLowerCase() !== i.reported.toLowerCase()) {
    return { refusal: `WETH_ADDRESS ${i.wethAddress} differs from the underlying the token reports (${i.reported}). Unset WETH_ADDRESS or fix it.` };
  }
  return { underlying: i.reported };
}

// Printed as soon as a deploy transaction is sent, before waiting for it to be mined,
// so the address and hash are on screen even if the RPC drops during the wait.
export function sentLine(name: string, address: string, hash: string): string {
  return `${name}: ${address} (tx ${hash}, waiting…)`;
}
