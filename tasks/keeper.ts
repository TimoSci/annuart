// The keeper: triggers and finishes due automatic payouts. Anyone may run it with their own key.
// The decisions (keeperPlan, keeperRefusal) are pure; runKeeperPass does the chain I/O through the
// objects it is given, so scripts/keeper.ts and the tests share it.
import { redact } from "./preflight";

// `fee` is the token's trigger fee in wei, as set by its owner. `lastPaidWei` is the token's
// last payout in wei, or null if it has never had one.
export type KeeperToken = { tokenId: bigint; pending: boolean; due: boolean; lastPaidWei: bigint | null; fee: bigint };

// The fee a request is likely to earn. The contract pays the requester the token's fee or a
// tenth of the payout, whichever is less, so the fee an owner advertises is only an upper
// bound; the last payout is the best guide to the next. Before a first payout only the
// advertised fee is known.
export function expectedFee(t: Pick<KeeperToken, "fee" | "lastPaidWei">): bigint {
  if (t.lastPaidWei === null) return t.fee;
  const tenth = t.lastPaidWei / 10n;
  return tenth < t.fee ? tenth : t.fee;
}

// `finish` is every pending token, whatever its fee; `request` every due, not pending token whose
// expected fee is at least minFee, minus those whose last payout was zero unless includeDry.
export function keeperPlan(
  tokens: KeeperToken[],
  opts: { includeDry: boolean; minFee: bigint },
): { finish: bigint[]; request: bigint[] } {
  const finish = tokens.filter((t) => t.pending).map((t) => t.tokenId);
  const request = tokens
    .filter((t) => !t.pending && t.due && expectedFee(t) >= opts.minFee && (opts.includeDry || t.lastPaidWei !== 0n))
    .map((t) => t.tokenId);
  return { finish, request };
}

// KEEPER_MIN_FEE: the smallest fee, in wei, worth paying gas for. Unset or empty means 0.
export function keeperMinFee(raw: string | undefined): bigint {
  if (raw === undefined || raw === "") return 0n;
  if (!/^[0-9]+$/.test(raw)) {
    throw new Error(`KEEPER_MIN_FEE must be a whole number of wei (for example 1000000000000000), not "${raw}".`);
  }
  return BigInt(raw);
}

// KEEPER_TIMEOUT: how long, in seconds, to wait for one decryption or one transaction to be
// mined before giving up on that token for this pass. Unset or empty means 60.
export const DEFAULT_TIMEOUT_MS = 60_000;
export function keeperTimeoutMs(raw: string | undefined): number {
  if (raw === undefined || raw === "") return DEFAULT_TIMEOUT_MS;
  if (!/^[1-9][0-9]*$/.test(raw)) {
    throw new Error(`KEEPER_TIMEOUT must be a whole number of seconds above zero (for example 120), not "${raw}".`);
  }
  return Number(raw) * 1000;
}

// Rejects with `message` if `work` has not settled within `ms`. The work itself is not stopped.
function within<T>(work: Promise<T>, ms: number, message: () => string): Promise<T> {
  let timer: ReturnType<typeof setTimeout>;
  const late = new Promise<never>((_, reject) => {
    timer = setTimeout(() => reject(new Error(message())), ms);
  });
  return Promise.race([work, late]).finally(() => clearTimeout(timer));
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
  // Due tokens whose fee is below this (wei) are not requested.
  minFee: bigint;
  // How long to wait for one decryption or one mined transaction. Default DEFAULT_TIMEOUT_MS.
  timeoutMs?: number;
  log: (line: string) => void;
  // Values to hide in printed errors (the keyed RPC URL).
  secrets?: ReadonlyArray<string | undefined>;
};
const SCAN_CHUNK = 20;
const ZERO_ID = `0x${"0".repeat(64)}`;

export type KeeperResult = { requested: number; finished: number; failed: number };

export async function runKeeperPass(input: KeeperPassInput): Promise<KeeperResult> {
  const { publicDecrypt, includeDry, minFee, log } = input;
  const timeoutMs = input.timeoutMs ?? DEFAULT_TIMEOUT_MS;
  const seconds = `${timeoutMs / 1000} s`;
  const result: KeeperResult = { requested: 0, finished: 0, failed: 0 };
  const fail = (what: string, e: unknown) => {
    result.failed++;
    const e2 = e as { shortMessage?: string; message?: string };
    log(`${what}: FAILED: ${redact(e2?.shortMessage ?? e2?.message ?? String(e), input.secrets ?? [])}`);
  };
  // A relayer that never answers, or a transaction that is never mined, costs one token its
  // turn, not the rest of the pass.
  const mined = (tx: TxResponse) =>
    within(tx.wait(), timeoutMs, () => `the transaction ${tx.hash} was not mined within ${seconds}`);

  for (const { label, contract: c } of input.contracts) {
    const finish = async (tokenId: bigint) => {
      const what = `${label} #${tokenId}`;
      try {
        const { requestId } = await c.pendingPayoutOf(tokenId);
        const d = await within(publicDecrypt([requestId]), timeoutMs, () => `the decryption timed out after ${seconds}`);
        // The plugin types the value as bigint | boolean | string; for this handle it is a bigint.
        const amount = BigInt(d.clearValues[requestId] as bigint);
        // The finaliser needs headroom for each ETH send, so give it the estimate plus 20%.
        const gasLimit = ((await c.finalizePayout.estimateGas(tokenId, amount, d.decryptionProof)) * 120n) / 100n;
        const tx = await c.finalizePayout(tokenId, amount, d.decryptionProof, { gasLimit });
        log(`${what}: finalising payout (tx ${tx.hash}, waiting…)`);
        await mined(tx);
        result.finished++;
        log(`${what}: payout finished`);
        return true;
      } catch (e) {
        fail(`${what}: finishing`, e);
        return false;
      }
    };

    // Two reads tell whether a token needs anything; only one that is due gets the two more
    // that decide whether it is worth requesting. A token that cannot be read fails alone.
    const read = async (tokenId: bigint): Promise<KeeperToken | null> => {
      try {
        const [pending, due] = await Promise.all([c.pendingPayoutOf(tokenId), c.payoutDue(tokenId)]);
        const t: KeeperToken = { tokenId, pending: pending.requestId !== ZERO_ID, due, lastPaidWei: null, fee: 0n };
        if (t.pending || !t.due) return t;
        const [last, settings] = await Promise.all([c.lastPayoutOf(tokenId), c.autoPayoutOf(tokenId)]);
        return { ...t, lastPaidWei: last.paidAt === 0n ? null : last.amountWei, fee: settings.fee };
      } catch (e) {
        fail(`${label} #${tokenId}: reading`, e);
        return null;
      }
    };

    // Read the tokens SCAN_CHUNK ids at a time. If the count cannot be read, this contract
    // loses its turn (one failure) but the other contracts do not.
    let total: bigint;
    try {
      total = await c.totalMinted();
    } catch (e) {
      fail(`${label}: reading tokens`, e);
      continue;
    }
    const tokens: KeeperToken[] = [];
    for (let from = 1n; from <= total; from += BigInt(SCAN_CHUNK)) {
      const ids: bigint[] = [];
      for (let id = from; id <= total && id < from + BigInt(SCAN_CHUNK); id++) ids.push(id);
      for (const t of await Promise.all(ids.map(read))) if (t) tokens.push(t);
    }
    const plan = keeperPlan(tokens, { includeDry, minFee });
    const fees = new Map(tokens.map((t) => [t.tokenId, t.fee]));
    log(`${label}: ${tokens.length} token(s), ${plan.finish.length} to finish, ${plan.request.length} to request`);

    for (const id of plan.finish) await finish(id);

    const requested: bigint[] = [];
    for (const id of plan.request) {
      const what = `${label} #${id}`;
      try {
        // The fee the plan was made with: an owner lowering it since makes the request fail
        // rather than pay less than was judged worth the gas.
        const tx = await c.requestPayout(id, fees.get(id)!);
        log(`${what}: requesting payout (tx ${tx.hash}, waiting…)`);
        await mined(tx);
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

// Exit code of a keeper run: 1 if any token (or contract scan) failed.
export function keeperExitCode(r: { failed: number }): number {
  return r.failed > 0 ? 1 : 0;
}
