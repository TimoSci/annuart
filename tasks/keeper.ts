// The keeper: triggers and finishes due automatic payouts. Anyone may run it with their own key.
// The decisions (keeperPlan, keeperRefusal) are pure; runKeeperPass does the chain I/O through the
// objects it is given, so scripts/keeper.ts and the tests share it.
import { redact } from "./preflight";

export type KeeperToken = { tokenId: bigint; pending: boolean; due: boolean; lastPaidZero: boolean };

// `finish` is every pending token; `request` every due, not pending token, minus those whose
// last payout was zero unless includeDry.
export function keeperPlan(tokens: KeeperToken[], opts: { includeDry: boolean }): { finish: bigint[]; request: bigint[] } {
  const finish = tokens.filter((t) => t.pending).map((t) => t.tokenId);
  const request = tokens
    .filter((t) => !t.pending && t.due && (opts.includeDry || !t.lastPaidZero))
    .map((t) => t.tokenId);
  return { finish, request };
}

export function keeperRefusal(i: { network: string; isLocal: boolean; confirm: string | undefined }): string | null {
  if (i.isLocal) return null;
  if (i.confirm !== i.network) {
    return `Refusing to send transactions to the public network "${i.network}" without confirmation. Re-run with CONFIRM_KEEPER=${i.network}.`;
  }
  return null;
}

// The parts of an AutoPayoutEndowmentNFT contract (connected to the keeper's signer) the pass uses.
type TxResponse = { hash: string; wait(): Promise<unknown> };
export type KeeperContract = {
  totalMinted(): Promise<bigint>;
  payoutDue(tokenId: bigint): Promise<boolean>;
  pendingPayoutOf(tokenId: bigint): Promise<{ requestId: string }>;
  lastPayoutOf(tokenId: bigint): Promise<{ paidAt: bigint; amountWei: bigint }>;
  autoPayoutOf(tokenId: bigint): Promise<{ fee: bigint }>;
  requestPayout(tokenId: bigint, minFee: bigint): Promise<TxResponse>;
  finalizePayout: {
    (tokenId: bigint, amount: bigint, proof: string, overrides?: { gasLimit: bigint }): Promise<TxResponse>;
    estimateGas(tokenId: bigint, amount: bigint, proof: string): Promise<bigint>;
  };
};
export type PublicDecrypt = (handles: string[]) => Promise<{
  clearValues: Record<string, bigint | boolean | string>;
  decryptionProof: string;
}>;

export type KeeperPassInput = {
  contracts: { label: string; contract: KeeperContract }[];
  publicDecrypt: PublicDecrypt;
  includeDry: boolean;
  log: (line: string) => void;
  // Values to hide in printed errors (the keyed RPC URL).
  secrets?: ReadonlyArray<string | undefined>;
};
export type KeeperResult = { requested: number; finished: number; failed: number };

export async function runKeeperPass(input: KeeperPassInput): Promise<KeeperResult> {
  const { publicDecrypt, includeDry, log } = input;
  const result: KeeperResult = { requested: 0, finished: 0, failed: 0 };
  const fail = (what: string, e: unknown) => {
    result.failed++;
    const e2 = e as { shortMessage?: string; message?: string };
    log(`${what}: FAILED: ${redact(e2?.shortMessage ?? e2?.message ?? String(e), input.secrets ?? [])}`);
  };

  for (const { label, contract: c } of input.contracts) {
    const finish = async (tokenId: bigint) => {
      const what = `${label} #${tokenId}`;
      try {
        const { requestId } = await c.pendingPayoutOf(tokenId);
        const d = await publicDecrypt([requestId]);
        const amount = BigInt(d.clearValues[requestId] as bigint);
        // The finaliser needs headroom for each ETH send, so give it the estimate plus 20%.
        const gasLimit = ((await c.finalizePayout.estimateGas(tokenId, amount, d.decryptionProof)) * 120n) / 100n;
        const tx = await c.finalizePayout(tokenId, amount, d.decryptionProof, { gasLimit });
        log(`${what}: finalising payout (tx ${tx.hash}, waiting…)`);
        await tx.wait();
        result.finished++;
        log(`${what}: payout finished`);
        return true;
      } catch (e) {
        fail(`${what}: finishing`, e);
        return false;
      }
    };

    const tokens: KeeperToken[] = [];
    const total = await c.totalMinted();
    for (let id = 1n; id <= total; id++) {
      const last = await c.lastPayoutOf(id);
      tokens.push({
        tokenId: id,
        pending: (await c.pendingPayoutOf(id)).requestId !== `0x${"0".repeat(64)}`,
        due: await c.payoutDue(id),
        lastPaidZero: last.paidAt !== 0n && last.amountWei === 0n,
      });
    }
    const plan = keeperPlan(tokens, { includeDry });
    log(`${label}: ${tokens.length} token(s), ${plan.finish.length} to finish, ${plan.request.length} to request`);

    for (const id of plan.finish) await finish(id);

    const requested: bigint[] = [];
    for (const id of plan.request) {
      const what = `${label} #${id}`;
      try {
        const { fee } = await c.autoPayoutOf(id);
        const tx = await c.requestPayout(id, fee);
        log(`${what}: requesting payout (tx ${tx.hash}, waiting…)`);
        await tx.wait();
        result.requested++;
        requested.push(id);
      } catch (e) {
        fail(`${what}: requesting`, e);
      }
    }
    for (const id of requested) await finish(id);
  }
  return result;
}
