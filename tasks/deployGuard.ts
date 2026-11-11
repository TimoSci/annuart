// Pure decision logic for scripts/deploy.ts: no I/O, so it can be unit-tested.
export type GuardInput = {
  network: string; isLocal: boolean; chainId: number; expectedChainId: number | undefined;
  confirm: string | undefined; label: string; existingLabels: string[]; replace: boolean;
};

// Returns the reason to refuse, or null to go ahead. Local networks are never refused.
export function deployRefusal(i: GuardInput): string | null {
  if (i.isLocal) return null;
  if (i.expectedChainId !== undefined && i.chainId !== i.expectedChainId) {
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
