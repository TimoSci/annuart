// Chain actions: every write the app makes, and the reads that need a signer
// or a decryption. Each action takes (session, contract, args, onStep), where
// `contract` is an entry of chainInfo().contracts and onStep(stepId, state,
// detail?) reports progress with state "active" | "done" | "skipped" | "failed".
// Every piece of work runs inside the step that owns it; checks made before the
// first step (the chain check, wrap's amount check) belong to the first step.
// A failure marks that step "failed" with errors.explain(err) and rethrows.
import {Contract, ZeroAddress} from "ethers";
import {ensureChain} from "./signer.js";
import {getFhe} from "./fhe.js";
import {ActionError, explain} from "../errors.js";
import {formatAmount} from "../units.js";
import {NFT_ABI, TOKEN_ABI, WETH_ABI} from "./abi.js";

const YEAR = 365 * 86400;

async function withSteps(onStep, firstStep, fn) {
  const report = (id, state, detail) => onStep?.(id, state, detail);
  let active = null;
  let started = false;
  const steps = {
    // Runs `work` as step `id`. `doneDetail(result)` is reported with "done".
    async step(id, work, doneDetail) {
      active = id;
      started = true;
      report(id, "active");
      const result = await work();
      report(id, "done", doneDetail?.(result));
      active = null;
      return result;
    },
    skip(id) {
      started = true;
      report(id, "skipped");
    },
    // Sends a transaction under `sendId`, then waits for it, and runs
    // `onMined(receipt)`, under `minedId`.
    async send(sendId, minedId, sendTx, onMined = receipt => receipt) {
      const tx = await steps.step(sendId, sendTx);
      return steps.step(minedId, async () => onMined(await tx.wait()));
    },
    // Sends, waits for and reads a transaction under one step.
    sendAndWait: (id, sendTx, onMined = receipt => receipt, doneDetail) =>
      steps.step(id, async () => onMined(await (await sendTx()).wait()), doneDetail),
  };
  try {
    return await fn(steps);
  } catch (err) {
    // With all work inside steps, nothing can fail between two steps. A step
    // already reported done or skipped is never marked failed.
    const failed = active ?? (started ? null : firstStep);
    if (failed) report(failed, "failed", explain(err));
    throw err;
  }
}

const nftOf = (contract, runner) => new Contract(contract.nft, NFT_ABI, runner);
const tokenOf = (contract, runner) => new Contract(contract.token, TOKEN_ABI, runner);
const wethOf = (contract, runner) => new Contract(contract.underlying, WETH_ABI, runner);

function findEvent(receipt, target, name) {
  for (const log of receipt.logs) {
    if (log.address.toLowerCase() !== target.target.toLowerCase()) continue;
    let parsed = null;
    try { parsed = target.interface.parseLog(log); } catch { /* not one of ours */ }
    if (parsed?.name === name) return parsed;
  }
  throw new Error(`the transaction did not emit ${name}`);
}

// A year from the chain's clock, which is what setOperator compares against.
async function yearFromNow(session) {
  return (await session.provider.getBlock("latest")).timestamp + YEAR;
}

function requireKind(contract, kind, message) {
  if (contract.tokenKind !== kind) throw new Error(message);
}

// The NFT must be an operator on the holder's tokens before it can pull them.
async function authoriseIfNeeded(steps, s, contract) {
  const token = tokenOf(contract, s.signer);
  if (await token.isOperator(s.address, contract.nft)) return steps.skip("authorise");
  await steps.sendAndWait("authorise", async () => token.setOperator(contract.nft, await yearFromNow(s)));
}

export function createEnft(session, contract, {to, amount, segments, start, topUps}, onStep) {
  return withSteps(onStep, "authorise", async steps => {
    const s = await ensureChain(session);
    await authoriseIfNeeded(steps, s, contract);
    const enc = await steps.step("encrypt", async () => (await getFhe(s)).encrypt64(contract.nft, s.address, amount));
    const nft = nftOf(contract, s.signer);
    const schedule = segments.map(({duration, ratePerSec}) => ({duration, ratePerSec}));
    return steps.send("confirm", "mined",
      () => nft.mint(to, enc.handle, enc.inputProof, schedule, start, topUps),
      receipt => ({hash: receipt.hash, tokenId: findEvent(receipt, nft, "EndowmentMinted").args.tokenId}));
  });
}

export function donate(session, contract, {tokenId, amount}, onStep) {
  return withSteps(onStep, "authorise", async steps => {
    const s = await ensureChain(session);
    await authoriseIfNeeded(steps, s, contract);
    const enc = await steps.step("encrypt", async () => (await getFhe(s)).encrypt64(contract.nft, s.address, amount));
    const nft = nftOf(contract, s.signer);
    const receipt = await steps.send("confirm", "mined", () => nft.topUp(tokenId, enc.handle, enc.inputProof));
    return {hash: receipt.hash};
  });
}

// An action that is one transaction: steps "confirm", "mined".
function single(session, onStep, sendTx) {
  return withSteps(onStep, "confirm", async steps => {
    const s = await ensureChain(session);
    const receipt = await steps.send("confirm", "mined", () => sendTx(s));
    return {hash: receipt.hash};
  });
}

export const claim = (session, contract, {tokenId}, onStep) =>
  single(session, onStep, s => nftOf(contract, s.signer).claim(tokenId));

export const accrue = (session, contract, {tokenId}, onStep) =>
  single(session, onStep, s => nftOf(contract, s.signer).accrue(tokenId));

export const transfer = (session, contract, {tokenId, to}, onStep) =>
  single(session, onStep, s => nftOf(contract, s.signer).safeTransferFrom(s.address, to, tokenId));

export function authorise(session, contract, _args, onStep) {
  return withSteps(onStep, "confirm", async steps => {
    const s = await ensureChain(session);
    let until;
    const receipt = await steps.send("confirm", "mined", async () => {
      until = await yearFromNow(s);
      return tokenOf(contract, s.signer).setOperator(contract.nft, until);
    });
    return {hash: receipt.hash, until};
  });
}

export async function faucet(session, contract, {amount}, onStep) {
  requireKind(contract, "mock", "The faucet only works with the mock token.");
  return single(session, onStep, s => tokenOf(contract, s.signer).mint(s.address, amount));
}

// ETH -> WETH -> confidential WETH. The wrapper takes whole multiples of
// rate(), so `wei` is rounded down to one. WETH the wallet already holds counts
// towards it: a retry after a failed approve or wrap does not deposit again.
export async function wrap(session, contract, {wei}, onStep) {
  requireKind(contract, "wrapped", "Only a wrapped token can be wrapped.");
  return withSteps(onStep, "deposit", async steps => {
    const s = await ensureChain(session);
    const weth = wethOf(contract, s.signer);
    const token = tokenOf(contract, s.signer);
    const rate = await token.rate();
    const amount = wei - (wei % rate);
    if (amount === 0n) throw new ActionError(`Wrap at least ${formatAmount(rate, 18)} ETH.`);
    const held = await weth.balanceOf(s.address);
    if (held >= amount) steps.skip("deposit");
    else await steps.sendAndWait("deposit", () => weth.deposit({value: amount - held}));
    await steps.sendAndWait("approve", () => weth.approve(contract.token, amount));
    const receipt = await steps.send("wrap", "mined", () => token.wrap(s.address, amount));
    return {hash: receipt.hash};
  });
}

// Confidential WETH -> WETH -> ETH. Once "request" is mined the amount is
// burnt and the request stays pending until finalised: its id is reported with
// "request" done, and any later error carries it as err.requestId, so the
// unwrap can be finished with finaliseUnwrap (see pendingUnwraps).
export async function unwrap(session, contract, {amount}, onStep) {
  requireKind(contract, "wrapped", "Only a wrapped token can be unwrapped.");
  return withSteps(onStep, "encrypt", async steps => {
    const s = await ensureChain(session);
    const token = tokenOf(contract, s.signer);
    const enc = await steps.step("encrypt", async () => (await getFhe(s)).encrypt64(contract.token, s.address, amount));
    const requestId = await steps.sendAndWait("request",
      () => token.unwrap(s.address, s.address, enc.handle, enc.inputProof),
      receipt => findEvent(receipt, token, "UnwrapRequested").args.unwrapRequestId,
      id => ({requestId: id}));
    try {
      return await completeUnwrap(steps, s, contract, requestId);
    } catch (err) {
      if (err && typeof err === "object") err.requestId = requestId;
      throw err;
    }
  });
}

// Finishes a pending unwrap request: steps "decrypt", "finalise", "withdraw", "mined".
export async function finaliseUnwrap(session, contract, {requestId}, onStep) {
  requireKind(contract, "wrapped", "Only a wrapped token can be unwrapped.");
  return withSteps(onStep, "decrypt", async steps => completeUnwrap(steps, await ensureChain(session), contract, requestId));
}

// The wrapper made the burnt amount publicly decryptable; its cleartext and
// the decryption proof finalise the request, which pays out WETH.
async function completeUnwrap(steps, s, contract, requestId) {
  const token = tokenOf(contract, s.signer);
  const {clear, proof} = await steps.step("decrypt", async () => {
    if ((await token.unwrapRequester(requestId)) === ZeroAddress) {
      throw new ActionError("This unwrap has already been finished.");
    }
    const {values, proof} = await (await getFhe(s)).publicDecrypt([requestId]);
    const clear = values.get(requestId);
    if (typeof clear !== "bigint") {
      throw new ActionError("The unwrap amount could not be decrypted. Try finishing the unwrap again later.");
    }
    return {clear, proof};
  });
  await steps.sendAndWait("finalise", () => token.finalizeUnwrap(requestId, clear, proof));
  const receipt = await steps.send("withdraw", "mined",
    async () => wethOf(contract, s.signer).withdraw(clear * (await token.rate())));
  return {hash: receipt.hash};
}

// WETH -> ETH, for WETH left behind by an unwrap whose withdraw failed.
export async function withdrawWeth(session, contract, {wei}, onStep) {
  requireKind(contract, "wrapped", "Only a wrapped token has WETH to withdraw.");
  return single(session, onStep, s => wethOf(contract, s.signer).withdraw(wei));
}

// Reads.

export async function revealDistribution(session, contract, tokenId) {
  const s = await ensureChain(session);
  const handle = await nftOf(contract, s.provider).distributionHandle(tokenId);
  const values = await (await getFhe(s)).userDecrypt([{handle, contractAddress: contract.nft}], s);
  return values.get(handle);
}

export async function revealBalance(session, contract) {
  const s = await ensureChain(session);
  const handle = await tokenOf(contract, s.provider).confidentialBalanceOf(s.address);
  const values = await (await getFhe(s)).userDecrypt([{handle, contractAddress: contract.token}], s);
  return values.get(handle);
}

export async function operatorStatus(session, contract) {
  const s = await ensureChain(session);
  const token = tokenOf(contract, s.provider);
  const authorised = await token.isOperator(s.address, contract.nft);
  const logs = await token.queryFilter(token.filters.OperatorSet(s.address, contract.nft), contract.deployBlock);
  const latest = logs.at(-1);
  return {authorised, until: latest ? Number(latest.args.until) : null};
}

// Unwrap requests paid to the session's address that are still pending. A
// request is pending while the wrapper still maps its id to a receiver:
// finalizeUnwrap deletes that entry, so unwrapRequester(id) is then zero.
export async function pendingUnwraps(session, contract) {
  requireKind(contract, "wrapped", "Only a wrapped token can be unwrapped.");
  const s = await ensureChain(session);
  const token = tokenOf(contract, s.provider);
  const logs = await token.queryFilter(token.filters.UnwrapRequested(s.address), contract.deployBlock);
  const pending = [];
  for (const log of logs) {
    const {unwrapRequestId: requestId, amount: amountHandle} = log.args;
    if ((await token.unwrapRequester(requestId)) !== ZeroAddress) pending.push({requestId, amountHandle});
  }
  return pending;
}

export async function wethBalance(session, contract) {
  requireKind(contract, "wrapped", "Only a wrapped token has WETH.");
  const s = await ensureChain(session);
  return wethOf(contract, s.provider).balanceOf(s.address);
}

export async function ethBalance(session) {
  const s = await ensureChain(session);
  return s.provider.getBalance(s.address);
}
