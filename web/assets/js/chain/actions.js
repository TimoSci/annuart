// Chain actions: every write the app makes, and the reads that need a signer
// or a decryption. Each action takes (session, contract, args, onStep), where
// `contract` is an entry of chainInfo().contracts and onStep(stepId, state,
// detail?) reports progress with state "active" | "done" | "skipped" | "failed".
// A failure marks the step in progress (or the first step, if none had started)
// "failed" with errors.explain(err), and rethrows.
import {Contract} from "ethers";
import {ensureChain} from "./signer.js";
import {getFhe} from "./fhe.js";
import {explain} from "../errors.js";
import {NFT_ABI, TOKEN_ABI, WETH_ABI} from "./abi.js";

const YEAR = 365 * 86400;

async function withSteps(onStep, firstStep, fn) {
  const report = (id, state, detail) => onStep?.(id, state, detail);
  let active = null;
  const steps = {
    async step(id, work) {
      active = id;
      report(id, "active");
      const result = await work();
      report(id, "done");
      active = null;
      return result;
    },
    skip: id => report(id, "skipped"),
    // Sends a transaction under `sendId`, then waits for it under `minedId`.
    async send(sendId, minedId, sendTx) {
      const tx = await steps.step(sendId, sendTx);
      return steps.step(minedId, () => tx.wait());
    },
    // Sends and waits for a transaction under one step.
    sendAndWait: (id, sendTx) => steps.step(id, async () => (await sendTx()).wait()),
  };
  try {
    return await fn(steps);
  } catch (err) {
    report(active ?? firstStep, "failed", explain(err));
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
  const until = await yearFromNow(s);
  await steps.sendAndWait("authorise", () => token.setOperator(contract.nft, until));
}

export function createEnft(session, contract, {to, amount, segments, start, topUps}, onStep) {
  return withSteps(onStep, "authorise", async steps => {
    const s = await ensureChain(session);
    await authoriseIfNeeded(steps, s, contract);
    const enc = await steps.step("encrypt", async () => (await getFhe(s)).encrypt64(contract.nft, s.address, amount));
    const nft = nftOf(contract, s.signer);
    const schedule = segments.map(({duration, ratePerSec}) => ({duration, ratePerSec}));
    const receipt = await steps.send("confirm", "mined",
      () => nft.mint(to, enc.handle, enc.inputProof, schedule, start, topUps));
    return {hash: receipt.hash, tokenId: findEvent(receipt, nft, "EndowmentMinted").args.tokenId};
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
    const until = await yearFromNow(s);
    const receipt = await steps.send("confirm", "mined", () => tokenOf(contract, s.signer).setOperator(contract.nft, until));
    return {hash: receipt.hash, until};
  });
}

export async function faucet(session, contract, {amount}, onStep) {
  requireKind(contract, "mock", "The faucet only works with the mock token.");
  return single(session, onStep, s => tokenOf(contract, s.signer).mint(s.address, amount));
}

// ETH -> WETH -> confidential WETH. The wrapper takes whole multiples of rate();
// any remainder stays as WETH.
export async function wrap(session, contract, {wei}, onStep) {
  requireKind(contract, "wrapped", "Only a wrapped token can be wrapped.");
  return withSteps(onStep, "deposit", async steps => {
    const s = await ensureChain(session);
    const weth = wethOf(contract, s.signer);
    await steps.sendAndWait("deposit", () => weth.deposit({value: wei}));
    await steps.sendAndWait("approve", () => weth.approve(contract.token, wei));
    const receipt = await steps.send("wrap", "mined", () => tokenOf(contract, s.signer).wrap(s.address, wei));
    return {hash: receipt.hash};
  });
}

// Confidential WETH -> WETH -> ETH. The burnt amount is made publicly
// decryptable by the wrapper; its cleartext and proof finalise the unwrap.
export async function unwrap(session, contract, {amount}, onStep) {
  requireKind(contract, "wrapped", "Only a wrapped token can be unwrapped.");
  return withSteps(onStep, "encrypt", async steps => {
    const s = await ensureChain(session);
    const fhe = await getFhe(s);
    const token = tokenOf(contract, s.signer);
    const enc = await steps.step("encrypt", () => fhe.encrypt64(contract.token, s.address, amount));
    const requested = await steps.sendAndWait("request",
      () => token.unwrap(s.address, s.address, enc.handle, enc.inputProof));
    const requestId = findEvent(requested, token, "UnwrapRequested").args.unwrapRequestId;
    const {values, proof} = await steps.step("decrypt", () => fhe.publicDecrypt([requestId]));
    const clear = values.get(requestId);
    await steps.sendAndWait("finalise", () => token.finalizeUnwrap(requestId, clear, proof));
    const wei = clear * (await token.rate());
    const receipt = await steps.send("withdraw", "mined", () => wethOf(contract, s.signer).withdraw(wei));
    return {hash: receipt.hash};
  });
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

export async function ethBalance(session) {
  const s = await ensureChain(session);
  return s.provider.getBalance(s.address);
}
