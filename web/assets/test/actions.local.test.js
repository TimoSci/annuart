// Chain actions against a real local Hardhat node, with the dev signer and the
// mock FHE client (the same modules the dev bundle wires into the browser).
//
// Needs, from the repo root:
//   npx hardhat node
//   npx hardhat run scripts/deploy.ts --network localhost
//   TOKEN_KIND=wrapped npx hardhat run scripts/deploy.ts --network localhost
import test from "node:test";
import assert from "node:assert/strict";
import {readFileSync} from "node:fs";
import {JsonRpcProvider} from "ethers";

const RPC_URL = "http://127.0.0.1:8545";
const DEPLOYMENTS = new URL("../../../deployments/localhost.json", import.meta.url);

async function reachable() {
  try {
    const res = await fetch(RPC_URL, {
      method: "POST",
      headers: {"content-type": "application/json"},
      body: JSON.stringify({jsonrpc: "2.0", id: 1, method: "eth_chainId", params: []}),
    });
    return res.ok;
  } catch {
    return false;
  }
}

function readDeployments() {
  try { return JSON.parse(readFileSync(DEPLOYMENTS, "utf8")); } catch { return null; }
}

const deployments = readDeployments();
const skip = !(await reachable())
  ? `no Hardhat node at ${RPC_URL}: start \`npx hardhat node\` and deploy (see the top of this file)`
  : !deployments
    ? `no ${DEPLOYMENTS.pathname}: run scripts/deploy.ts for the mock and wrapped tokens`
    : false;
if (skip) console.log(`# actions.local.test.js skipped: ${skip}`);

// Browser globals the modules read: the chain meta tag and window.__annuartDev.
globalThis.window = globalThis;
const chain = {chainId: 31337, rpcUrl: RPC_URL, contracts: deployments?.contracts ?? []};
globalThis.document = {
  querySelector: sel => sel === "meta[name='annuart-chain']" ? {content: JSON.stringify(chain)} : null,
};

const actions = await import("../js/chain/actions.js");
const {explain} = await import("../js/errors.js");
const {createDevSigner} = await import("../js/chain/signer/dev.js");
const {createMockFhe} = await import("../js/chain/fhe/mock.js");
const {getFhe} = await import("../js/chain/fhe.js");

const provider = new JsonRpcProvider(RPC_URL, undefined, {cacheTimeout: -1, pollingInterval: 100});
const mock = chain.contracts.find(c => c.label === "mock");
const wrapped = chain.contracts.find(c => c.label === "wrapped");
const DAY = 86400;

let alice, bob, carol, dave;
if (!skip) {
  // As dev.js does in the browser: the mock FHE client is registered by the dev bundle.
  window.__annuartDev = {createFhe: session => createMockFhe(session, {provider})};
  alice = await createDevSigner({index: 1, provider});
  bob = await createDevSigner({index: 2, provider});
  carol = await createDevSigner({index: 3, provider});
  dave = await createDevSigner({index: 4, provider});
}

// The same session, but its wallet rejects the nth transaction it is asked to send.
function rejectingNth(session, n) {
  let sent = 0;
  const signer = new Proxy(session.signer, {
    get(target, prop) {
      if (prop === "sendTransaction") {
        return async tx => {
          if (++sent === n) {
            throw Object.assign(new Error("user rejected transaction"), {code: "ACTION_REJECTED"});
          }
          return target.sendTransaction(tx);
        };
      }
      const v = Reflect.get(target, prop, target);
      return typeof v === "function" ? v.bind(target) : v;
    },
  });
  return {...session, signer};
}

// Records onStep calls for one action.
function steps() {
  const log = [];
  const fn = (id, state, detail) => log.push({id, state, detail});
  fn.log = log;
  fn.ids = () => [...new Set(log.map(e => e.id))];
  fn.state = id => log.filter(e => e.id === id).at(-1)?.state;
  fn.detail = id => log.filter(e => e.id === id).at(-1)?.detail;
  fn.finalStates = () => fn.ids().map(id => fn.state(id));
  return fn;
}

async function increaseTime(seconds) {
  await provider.send("evm_increaseTime", [seconds]);
  await provider.send("evm_mine", []);
}

const chainNow = async () => (await provider.getBlock("latest")).timestamp;

// Sum of the fees `address` paid for transactions mined in blocks (from, to].
async function feesPaid(address, from, to) {
  let total = 0n;
  for (let n = from + 1; n <= to; n++) {
    const block = await provider.getBlock(n);
    for (const hash of block.transactions) {
      const tx = await provider.getTransaction(hash);
      if (tx.from.toLowerCase() !== address.toLowerCase()) continue;
      const r = await provider.getTransactionReceipt(hash);
      total += r.gasUsed * r.gasPrice;
    }
  }
  return total;
}

const createArgs = (to, extra = {}) => ({
  to, amount: 2_000n, segments: [{duration: 1000n, ratePerSec: 1n}], start: 0n, topUps: true, ...extra,
});

test("create -> accrue -> reveal -> claim on the mock token", {skip}, async () => {
  await actions.faucet(alice, mock, {amount: 5_000n}, steps());
  const st = steps();
  const {tokenId, hash} = await actions.createEnft(alice, mock, createArgs(alice.address), st);
  assert.deepEqual(st.ids(), ["authorise", "encrypt", "confirm", "mined"]);
  assert.ok(st.finalStates().every(s => s === "done" || s === "skipped"));
  assert.equal(typeof tokenId, "bigint");
  assert.match(hash, /^0x[0-9a-f]{64}$/);
  await increaseTime(100);
  const accrued = steps();
  await actions.accrue(bob, mock, {tokenId}, accrued); // anyone may accrue
  assert.deepEqual(accrued.ids(), ["confirm", "mined"]);
  const d = await actions.revealDistribution(alice, mock, tokenId);
  assert.ok(d >= 100n && d <= 110n, `distribution ${d}`);
  const claimed = steps();
  await actions.claim(alice, mock, {tokenId}, claimed);
  assert.deepEqual(claimed.ids(), ["confirm", "mined"]);
  assert.equal(await actions.revealDistribution(alice, mock, tokenId), 0n);
});

test("second create skips the authorise step", {skip}, async () => {
  const st = steps();
  await actions.createEnft(alice, mock, createArgs(alice.address), st);
  assert.equal(st.state("authorise"), "skipped");
  assert.deepEqual(st.log.filter(e => e.id === "authorise").map(e => e.state), ["skipped"]);
  assert.equal(st.state("mined"), "done");
});

test("donate, then transfer; the new owner can reveal and the old owner cannot", {skip}, async () => {
  const {tokenId} = await actions.createEnft(alice, mock, createArgs(alice.address), steps());
  await actions.faucet(bob, mock, {amount: 500n}, steps());
  const bobBefore = await actions.revealBalance(bob, mock);
  const st = steps();
  await actions.donate(bob, mock, {tokenId, amount: 300n}, st);
  assert.deepEqual(st.ids(), ["authorise", "encrypt", "confirm", "mined"]);
  assert.equal(await actions.revealBalance(bob, mock), bobBefore - 300n);

  await increaseTime(50);
  const tr = steps();
  await actions.transfer(alice, mock, {tokenId, to: bob.address}, tr);
  assert.deepEqual(tr.ids(), ["confirm", "mined"]);
  assert.equal((await provider.call({
    to: mock.nft, data: "0x6352211e" + tokenId.toString(16).padStart(64, "0"),
  })).slice(-40).toLowerCase(), bob.address.slice(2).toLowerCase());
  const d = await actions.revealDistribution(bob, mock, tokenId);
  assert.ok(d >= 50n && d <= 60n, `distribution ${d}`);
  await assert.rejects(() => actions.revealDistribution(alice, mock, tokenId));
});

test("leftover is released at the end", {skip}, async () => {
  await actions.faucet(alice, mock, {amount: 2_000n}, steps());
  const {tokenId} = await actions.createEnft(alice, mock, createArgs(alice.address), steps());
  const afterCreate = await actions.revealBalance(alice, mock);
  await increaseTime(1001);
  await actions.claim(alice, mock, {tokenId}, steps());
  assert.equal(await actions.revealBalance(alice, mock), afterCreate + 2_000n);
});

test("claim by a non-owner fails with the NotOwner message and marks the step failed", {skip}, async () => {
  const {tokenId} = await actions.createEnft(alice, mock, createArgs(alice.address), steps());
  const st = steps();
  await assert.rejects(
    () => actions.claim(bob, mock, {tokenId}, st),
    err => explain(err) === "Only the owner can do this.",
  );
  assert.equal(st.state("confirm"), "failed");
  assert.equal(st.detail("confirm"), "Only the owner can do this.");
  assert.equal(st.state("mined"), undefined);
  assert.ok(!st.finalStates().includes("active"));
});

test("donate to an ENFT with donations off fails with the TopUpsDisabled message", {skip}, async () => {
  const {tokenId} = await actions.createEnft(alice, mock, createArgs(alice.address, {topUps: false}), steps());
  await actions.faucet(bob, mock, {amount: 100n}, steps());
  const st = steps();
  await assert.rejects(
    () => actions.donate(bob, mock, {tokenId, amount: 100n}, st),
    err => explain(err) === "This ENFT does not accept donations.",
  );
  assert.equal(st.state("encrypt"), "done");
  assert.equal(st.state("confirm"), "failed");
  assert.equal(st.detail("confirm"), "This ENFT does not accept donations.");
  assert.ok(!st.finalStates().includes("active"));
});

test("wrap then unwrap on the wrapped token restores the ETH balance less gas", {skip}, async () => {
  const startBlock = await provider.getBlockNumber();
  const ethBefore = await actions.ethBalance(alice);
  const balBefore = await actions.revealBalance(alice, wrapped);

  const w = steps();
  await actions.wrap(alice, wrapped, {wei: 10n ** 18n}, w);
  assert.deepEqual(w.ids(), ["deposit", "approve", "wrap", "mined"]);
  // 9 decimals: 1 ether wraps to 1e9 units.
  assert.equal(await actions.revealBalance(alice, wrapped), balBefore + 10n ** 9n);

  const u = steps();
  await actions.unwrap(alice, wrapped, {amount: 10n ** 9n}, u);
  assert.deepEqual(u.ids(), ["encrypt", "request", "decrypt", "finalise", "withdraw", "mined"]);
  assert.ok(u.finalStates().every(s => s === "done"));
  assert.equal(await actions.revealBalance(alice, wrapped), balBefore);

  const ethAfter = await actions.ethBalance(alice);
  const gas = await feesPaid(alice.address, startBlock, await provider.getBlockNumber());
  assert.ok(gas > 0n);
  assert.equal(ethAfter, ethBefore - gas);
});

test("operatorStatus reports authorised and an expiry about a year out", {skip}, async () => {
  assert.deepEqual(await actions.operatorStatus(carol, mock), {authorised: false, until: null});

  const st = steps();
  const {until, hash} = await actions.authorise(alice, mock, {}, st);
  assert.deepEqual(st.ids(), ["confirm", "mined"]);
  const mined = (await provider.getBlock((await provider.getTransactionReceipt(hash)).blockNumber)).timestamp;
  assert.ok(Math.abs(until - (mined + 365 * DAY)) <= 5, `until ${until}, mined at ${mined}`);

  const status = await actions.operatorStatus(alice, mock);
  assert.equal(status.authorised, true);
  assert.equal(status.until, until);
  assert.ok(status.until > (await chainNow()) + 364 * DAY);
});

test("faucet refuses a token that is not the mock", {skip}, async () => {
  await assert.rejects(() => actions.faucet(alice, wrapped, {amount: 1n}, steps()), /mock token/);
});

// Recovery for wrap and unwrap. Dave (account 4) is used only here; each test
// first clears anything an earlier failed run may have left behind.
const ETHER = 10n ** 18n;
const UNIT = 10n ** 9n; // wei per confidential unit: rate() of the 9-decimal wrapper

async function cleanSlate(session) {
  for (const {requestId} of await actions.pendingUnwraps(session, wrapped)) {
    await actions.finaliseUnwrap(session, wrapped, {requestId}, steps());
  }
  const weth = await actions.wethBalance(session, wrapped);
  if (weth > 0n) await actions.withdrawWeth(session, wrapped, {wei: weth}, steps());
}

// ETH, WETH and confidential balance, plus the block they were read at.
async function snapshot(session) {
  return {
    block: await provider.getBlockNumber(),
    eth: await actions.ethBalance(session),
    weth: await actions.wethBalance(session, wrapped),
    conf: await actions.revealBalance(session, wrapped),
  };
}
const feesSince = async (session, snap) => feesPaid(session.address, snap.block, await provider.getBlockNumber());

test("wrap with approve rejected, retried, moves exactly one deposit's worth", {skip}, async () => {
  await cleanSlate(dave);
  const before = await snapshot(dave);

  const first = steps();
  await assert.rejects(
    () => actions.wrap(rejectingNth(dave, 2), wrapped, {wei: ETHER}, first),
    err => explain(err) === "You cancelled the request in your wallet.",
  );
  assert.equal(first.state("deposit"), "done");
  assert.equal(first.state("approve"), "failed");
  assert.equal(await actions.wethBalance(dave, wrapped), ETHER);

  const retry = steps();
  await actions.wrap(dave, wrapped, {wei: ETHER}, retry);
  assert.deepEqual(retry.ids(), ["deposit", "approve", "wrap", "mined"]);
  assert.equal(retry.state("deposit"), "skipped"); // the WETH from the first attempt is used

  assert.equal(await actions.wethBalance(dave, wrapped), 0n);
  assert.equal(await actions.revealBalance(dave, wrapped), before.conf + ETHER / UNIT);
  assert.equal(await actions.ethBalance(dave), before.eth - ETHER - await feesSince(dave, before));
});

test("wrap of an amount with dust leaves no WETH behind", {skip}, async () => {
  await cleanSlate(dave);
  const before = await snapshot(dave);
  await actions.wrap(dave, wrapped, {wei: ETHER + 123n}, steps());
  assert.equal(await actions.wethBalance(dave, wrapped), 0n);
  assert.equal(await actions.revealBalance(dave, wrapped), before.conf + ETHER / UNIT);
  assert.equal(await actions.ethBalance(dave), before.eth - ETHER - await feesSince(dave, before));
});

test("wrap below the wrapper's granularity throws before any transaction", {skip}, async () => {
  const block = await provider.getBlockNumber();
  const st = steps();
  await assert.rejects(() => actions.wrap(dave, wrapped, {wei: UNIT - 1n}, st), /at least/);
  assert.equal(await provider.getBlockNumber(), block);
  assert.equal(st.state("deposit"), "failed");
  assert.match(st.detail("deposit"), /^Wrap at least /);
});

test("unwrap with finalise rejected: pendingUnwraps lists it and finaliseUnwrap completes it", {skip}, async () => {
  await cleanSlate(dave);
  const before = await snapshot(dave);
  await actions.wrap(dave, wrapped, {wei: ETHER}, steps());

  const st = steps();
  let requestId;
  await assert.rejects(
    () => actions.unwrap(rejectingNth(dave, 2), wrapped, {amount: UNIT}, st),
    err => { requestId = err.requestId; return explain(err) === "You cancelled the request in your wallet."; },
  );
  assert.match(requestId, /^0x[0-9a-f]{64}$/);
  assert.equal(st.state("request"), "done");
  assert.deepEqual(st.detail("request"), {requestId});
  assert.equal(st.state("decrypt"), "done");
  assert.equal(st.state("finalise"), "failed");

  const pending = await actions.pendingUnwraps(dave, wrapped);
  assert.deepEqual(pending, [{requestId, amountHandle: requestId}]);

  const fin = steps();
  await actions.finaliseUnwrap(dave, wrapped, {requestId}, fin);
  assert.deepEqual(fin.ids(), ["decrypt", "finalise", "withdraw", "mined"]);
  assert.ok(fin.finalStates().every(s => s === "done"));

  assert.deepEqual(await actions.pendingUnwraps(dave, wrapped), []);
  assert.equal(await actions.wethBalance(dave, wrapped), 0n);
  assert.equal(await actions.revealBalance(dave, wrapped), before.conf);
  assert.equal(await actions.ethBalance(dave), before.eth - await feesSince(dave, before));
});

test("unwrap with withdraw rejected: wethBalance shows it and withdrawWeth recovers it", {skip}, async () => {
  await cleanSlate(dave);
  const before = await snapshot(dave);
  await actions.wrap(dave, wrapped, {wei: ETHER}, steps());

  const st = steps();
  await assert.rejects(
    () => actions.unwrap(rejectingNth(dave, 3), wrapped, {amount: UNIT}, st),
    err => typeof err.requestId === "string",
  );
  assert.equal(st.state("finalise"), "done");
  assert.equal(st.state("withdraw"), "failed");
  assert.deepEqual(await actions.pendingUnwraps(dave, wrapped), []);
  assert.equal(await actions.wethBalance(dave, wrapped), ETHER);

  const w = steps();
  await actions.withdrawWeth(dave, wrapped, {wei: ETHER}, w);
  assert.deepEqual(w.ids(), ["confirm", "mined"]);
  assert.equal(await actions.wethBalance(dave, wrapped), 0n);
  assert.equal(await actions.revealBalance(dave, wrapped), before.conf);
  assert.equal(await actions.ethBalance(dave), before.eth - await feesSince(dave, before));
});

test("a missing decrypted value fails the decrypt step, not the request step", {skip}, async () => {
  await cleanSlate(dave);
  await actions.wrap(dave, wrapped, {wei: ETHER}, steps());
  const fhe = await getFhe(dave);
  const realPublicDecrypt = fhe.publicDecrypt;
  fhe.publicDecrypt = async () => ({values: new Map(), proof: "0x"});
  const st = steps();
  let requestId;
  try {
    await assert.rejects(
      () => actions.unwrap(dave, wrapped, {amount: UNIT}, st),
      err => { requestId = err.requestId; return /could not be decrypted/.test(err.message); },
    );
  } finally {
    fhe.publicDecrypt = realPublicDecrypt;
  }
  assert.deepEqual(st.log.filter(e => e.id === "request").map(e => e.state), ["active", "done"]);
  assert.equal(st.state("decrypt"), "failed");
  assert.match(st.detail("decrypt"), /could not be decrypted/);
  assert.ok(!st.finalStates().includes("active"));
  // The request it left pending is recoverable.
  assert.deepEqual((await actions.pendingUnwraps(dave, wrapped)).map(p => p.requestId), [requestId]);
  await actions.finaliseUnwrap(dave, wrapped, {requestId}, steps());
  assert.deepEqual(await actions.pendingUnwraps(dave, wrapped), []);
});
