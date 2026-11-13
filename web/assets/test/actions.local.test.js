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
import {HDNodeWallet, JsonRpcProvider} from "ethers";

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

const store = new Map();
globalThis.localStorage = {
  getItem: k => store.get(k) ?? null, setItem: (k, v) => store.set(k, String(v)), removeItem: k => store.delete(k),
};

const actions = await import("../js/chain/actions.js");
const {explain} = await import("../js/errors.js");
const {formatAmount} = await import("../js/units.js");
const {createDevSigner} = await import("../js/chain/signer/dev.js");
const {createMockFhe} = await import("../js/chain/fhe/mock.js");
const {getFhe} = await import("../js/chain/fhe.js");

const provider = new JsonRpcProvider(RPC_URL, undefined, {cacheTimeout: -1, pollingInterval: 100});
const mock = chain.contracts.find(c => c.label === "mock");
const wrapped = chain.contracts.find(c => c.label === "wrapped");
const DAY = 86400;

let alice, bob, carol, dave, erin;
if (!skip) {
  // As dev.js does in the browser: the mock FHE client is registered by the dev bundle.
  window.__annuartDev = {createFhe: session => createMockFhe(session, {provider})};
  alice = await createDevSigner({index: 1, provider});
  bob = await createDevSigner({index: 2, provider});
  carol = await createDevSigner({index: 3, provider});
  dave = await createDevSigner({index: 4, provider});
  // Account 5 is outside the dev login's five: used only by the balance checks.
  const signer = HDNodeWallet.fromPhrase("test test test test test test test test test test test junk",
    undefined, "m/44'/60'/0'/0/5").connect(provider);
  erin = {kind: "dev", address: signer.address, signer, provider, chainId: 31337};
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

// The same session, but every transaction it sends is replaced before it is
// mined by a copy paying a higher fee (a wallet's "speed up"): same nonce, to,
// data and value. The original never mines; the replacement does.
function speedingUp(session) {
  const replaced = [];
  const signer = new Proxy(session.signer, {
    get(target, prop) {
      if (prop === "sendTransaction") {
        return async tx => {
          await provider.send("evm_setAutomine", [false]);
          try {
            const original = await target.sendTransaction(tx);
            const replacement = await target.sendTransaction({
              to: original.to, data: original.data, value: original.value, nonce: original.nonce,
              gasLimit: original.gasLimit, chainId: original.chainId,
              maxFeePerGas: original.maxFeePerGas * 2n, maxPriorityFeePerGas: original.maxPriorityFeePerGas * 2n,
            });
            await provider.send("evm_mine", []);
            replaced.push({original: original.hash, replacement: replacement.hash});
            return original;
          } finally {
            await provider.send("evm_setAutomine", [true]);
          }
        };
      }
      const v = Reflect.get(target, prop, target);
      return typeof v === "function" ? v.bind(target) : v;
    },
  });
  return {session: {...session, signer}, replaced};
}

// Records onStep calls for one action.
function steps() {
  const log = [];
  const fn = (id, state, detail) => log.push({id, state, detail});
  fn.sentLog = [];
  fn.sent = (id, hash) => fn.sentLog.push({id, hash});
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

// The symbol and decimals the balance check words its message with; the hooks
// pass the token's own.
const MOCK_UNITS = {symbol: "MOCK", decimals: 6};
const WRAPPED_UNITS = {symbol: "cWETH", decimals: 9};

const createArgs = (to, extra = {}) => ({
  to, amount: 2_000n, segments: [{duration: 1000n, ratePerSec: 1n}], start: 0n, topUps: true, ...MOCK_UNITS, ...extra,
});

// Gives `session` enough mock tokens for an action of `amount`.
const fund = (session, amount = 2_000n) => actions.faucet(session, mock, {amount}, steps());

test("create -> accrue -> reveal -> claim on the mock token", {skip}, async () => {
  await actions.faucet(alice, mock, {amount: 5_000n}, steps());
  const st = steps();
  const {tokenId, hash} = await actions.createEnft(alice, mock, createArgs(alice.address), st);
  assert.deepEqual(st.ids(), ["balance", "authorise", "encrypt", "confirm", "mined"]);
  // Both ways of sending report the broadcast: a one-step wait and a send/mined pair.
  assert.deepEqual(st.sentLog.map(e => e.id), ["authorise", "mined"]);
  assert.ok(st.sentLog.every(e => /^0x[0-9a-f]{64}$/.test(e.hash)));
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

test("a create with a name stores it on chain; without one the name is zero", {skip}, async () => {
  const {Contract, decodeBytes32String, ZeroHash} = await import("ethers");
  const nft = new Contract(mock.nft, ["function nameOf(uint256) view returns (bytes32)"], provider);
  await fund(alice, 4_000n);
  const named = await actions.createEnft(alice, mock, createArgs(alice.address, {name: "Rainy day fund"}), steps());
  assert.equal(decodeBytes32String(await nft.nameOf(named.tokenId)), "Rainy day fund");
  const unnamed = await actions.createEnft(alice, mock, createArgs(alice.address), steps());
  assert.equal(await nft.nameOf(unnamed.tokenId), ZeroHash);
});

test("a name the contract would refuse stops the create before anything is sent", {skip}, async () => {
  await fund(alice);
  const before = await provider.getTransactionCount(alice.address);
  const st = steps();
  await assert.rejects(() => actions.createEnft(alice, mock, createArgs(alice.address, {name: "<b>bold</b>"}), st));
  assert.equal(await provider.getTransactionCount(alice.address), before);
  assert.deepEqual(st.sentLog, []);
});

test("second create skips the authorise step", {skip}, async () => {
  await fund(alice);
  const st = steps();
  await actions.createEnft(alice, mock, createArgs(alice.address), st);
  assert.equal(st.state("authorise"), "skipped");
  assert.deepEqual(st.log.filter(e => e.id === "authorise").map(e => e.state), ["skipped"]);
  assert.equal(st.state("mined"), "done");
});

test("donate, then transfer; the new owner can reveal and the old owner cannot", {skip}, async () => {
  await fund(alice);
  const {tokenId} = await actions.createEnft(alice, mock, createArgs(alice.address), steps());
  await actions.faucet(bob, mock, {amount: 500n}, steps());
  const bobBefore = await actions.revealBalance(bob, mock);
  const st = steps();
  await actions.donate(bob, mock, {tokenId, amount: 300n, ...MOCK_UNITS}, st);
  assert.deepEqual(st.ids(), ["balance", "authorise", "encrypt", "confirm", "mined"]);
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
  await fund(alice);
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
  await fund(alice);
  const {tokenId} = await actions.createEnft(alice, mock, createArgs(alice.address, {topUps: false}), steps());
  await actions.faucet(bob, mock, {amount: 100n}, steps());
  const st = steps();
  await assert.rejects(
    () => actions.donate(bob, mock, {tokenId, amount: 100n, ...MOCK_UNITS}, st),
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
  await actions.unwrap(alice, wrapped, {amount: 10n ** 9n, ...WRAPPED_UNITS}, u);
  assert.deepEqual(u.ids(), ["balance", "encrypt", "request", "decrypt", "finalise", "withdraw", "mined"]);
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
    () => actions.unwrap(rejectingNth(dave, 2), wrapped, {amount: UNIT, ...WRAPPED_UNITS}, st),
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
    () => actions.unwrap(rejectingNth(dave, 3), wrapped, {amount: UNIT, ...WRAPPED_UNITS}, st),
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
      () => actions.unwrap(dave, wrapped, {amount: UNIT, ...WRAPPED_UNITS}, st),
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

// The balance check: ERC-7984 moves zero, without reverting, when asked for
// more than the balance, so each action that spends the confidential balance
// refuses that before it sends anything.
const ungrouped = (units, decimals) => formatAmount(units, decimals, {grouping: false});

async function expectRefusedForBalance(run, balance, units) {
  const block = await provider.getBlockNumber();
  const st = steps();
  const message = `You only have ${ungrouped(balance, units.decimals)} ${units.symbol}.`;
  await assert.rejects(() => run(st), err => explain(err) === message);
  assert.equal(await provider.getBlockNumber(), block, "no transaction was sent");
  assert.deepEqual(st.ids(), ["balance"]);
  assert.equal(st.state("balance"), "failed");
  assert.equal(st.detail("balance"), message);
}

test("create above the balance fails in the balance step; at exactly the balance it succeeds", {skip}, async () => {
  await fund(erin, 5_000_000_000n);
  const balance = await actions.revealBalance(erin, mock);
  assert.ok(balance >= 5_000_000_000n);
  await expectRefusedForBalance(
    st => actions.createEnft(erin, mock, createArgs(erin.address, {amount: balance + 1n}), st), balance, MOCK_UNITS);
  assert.doesNotMatch(`${ungrouped(balance, 6)}`, /,/);

  const st = steps();
  const {tokenId} = await actions.createEnft(erin, mock, createArgs(erin.address, {amount: balance}), st);
  assert.equal(st.state("balance"), "done");
  assert.equal(typeof tokenId, "bigint");
  assert.equal(await actions.revealBalance(erin, mock), 0n);
});

test("donate above the balance fails in the balance step; at exactly the balance it succeeds", {skip}, async () => {
  await fund(alice);
  const {tokenId} = await actions.createEnft(alice, mock, createArgs(alice.address), steps());
  await fund(erin, 300n);
  const balance = await actions.revealBalance(erin, mock);
  await expectRefusedForBalance(
    st => actions.donate(erin, mock, {tokenId, amount: balance + 1n, ...MOCK_UNITS}, st), balance, MOCK_UNITS);

  const st = steps();
  await actions.donate(erin, mock, {tokenId, amount: balance, ...MOCK_UNITS}, st);
  assert.equal(st.state("mined"), "done");
  assert.equal(await actions.revealBalance(erin, mock), 0n);
});

test("unwrap above the balance fails in the balance step; at exactly the balance it succeeds", {skip}, async () => {
  await cleanSlate(erin);
  await actions.wrap(erin, wrapped, {wei: ETHER}, steps());
  const balance = await actions.revealBalance(erin, wrapped);
  await expectRefusedForBalance(
    st => actions.unwrap(erin, wrapped, {amount: balance + 1n, ...WRAPPED_UNITS}, st), balance, WRAPPED_UNITS);
  assert.deepEqual(await actions.pendingUnwraps(erin, wrapped), []);

  const st = steps();
  await actions.unwrap(erin, wrapped, {amount: balance, ...WRAPPED_UNITS}, st);
  assert.ok(st.finalStates().every(s => s === "done"));
  assert.equal(await actions.revealBalance(erin, wrapped), 0n);
});

// A wallet's "speed up" replaces the transaction with a copy at a higher fee.
// ethers reports that from wait() as TRANSACTION_REPLACED, reason "repriced",
// with the replacement's receipt: the action went through.
test("a transaction repriced in the wallet counts as mined, with the replacement's receipt", {skip, timeout: 30_000}, async () => {
  await fund(alice);
  const {session, replaced} = speedingUp(alice);
  const st = steps();
  const {tokenId, hash} = await actions.createEnft(session, mock, createArgs(alice.address), st);
  assert.ok(replaced.length >= 1);
  const last = replaced.at(-1);
  assert.equal(hash, last.replacement);
  assert.notEqual(hash, last.original);
  assert.equal(await provider.getTransaction(last.original), null, "the original never mined");
  assert.equal(st.state("mined"), "done");
  assert.equal(typeof tokenId, "bigint");

  // A one-step action (sent and waited for under one step) too.
  const claimed = steps();
  const claimSpeed = speedingUp(alice);
  const res = await actions.claim(claimSpeed.session, mock, {tokenId}, claimed);
  assert.equal(res.hash, claimSpeed.replaced.at(-1).replacement);
  assert.equal(claimed.state("mined"), "done");
});

// A replacement that does something else (a cancel) is not success.
test("a transaction cancelled in the wallet fails the step that waited for it", {skip, timeout: 30_000}, async () => {
  await fund(alice);
  const cancel = new Proxy(alice.signer, {
    get(target, prop) {
      if (prop === "sendTransaction") {
        return async tx => {
          await provider.send("evm_setAutomine", [false]);
          try {
            const original = await target.sendTransaction(tx);
            await target.sendTransaction({
              to: alice.address, data: "0x", value: 0n, nonce: original.nonce, gasLimit: 21_000n,
              chainId: original.chainId,
              maxFeePerGas: original.maxFeePerGas * 2n, maxPriorityFeePerGas: original.maxPriorityFeePerGas * 2n,
            });
            await provider.send("evm_mine", []);
            return original;
          } finally {
            await provider.send("evm_setAutomine", [true]);
          }
        };
      }
      const v = Reflect.get(target, prop, target);
      return typeof v === "function" ? v.bind(target) : v;
    },
  });
  const st = steps();
  await assert.rejects(
    () => actions.createEnft({...alice, signer: cancel}, mock, createArgs(alice.address), st),
    err => err.code === "TRANSACTION_REPLACED" && err.reason === "cancelled" && /^0x[0-9a-f]{64}$/.test(err.sentHash),
  );
  assert.equal(st.state("confirm"), "done");
  assert.equal(st.state("mined"), "failed");
});

test("finishing an unwrap that was already finished points to Convert to ETH", {skip}, async () => {
  await cleanSlate(dave);
  await actions.wrap(dave, wrapped, {wei: ETHER}, steps());
  let requestId;
  await assert.rejects(
    () => actions.unwrap(rejectingNth(dave, 2), wrapped, {amount: UNIT, ...WRAPPED_UNITS}, steps()),
    err => { requestId = err.requestId; return true; },
  );
  await actions.finaliseUnwrap(dave, wrapped, {requestId}, steps());
  const block = await provider.getBlockNumber();
  const st = steps();
  await assert.rejects(() => actions.finaliseUnwrap(dave, wrapped, {requestId}, st));
  assert.equal(st.state("decrypt"), "failed");
  assert.equal(st.detail("decrypt"),
    "This unwrap has already been finished. If the ETH did not arrive, use Convert to ETH below.");
  assert.equal(await provider.getBlockNumber(), block);
});

test("an unwrap request older than the log look-back is found from storage until it is finished", {skip}, async () => {
  await cleanSlate(dave);
  await actions.wrap(dave, wrapped, {wei: ETHER}, steps());
  let requestId;
  await assert.rejects(
    () => actions.unwrap(rejectingNth(dave, 2), wrapped, {amount: UNIT, ...WRAPPED_UNITS}, steps()),
    err => { requestId = err.requestId; return true; },
  );
  const key = `annuart:unwraps:31337:${wrapped.token}:${dave.address}`.toLowerCase();
  // Earlier finished requests may still be remembered (kept 12 blocks): this one is last.
  assert.equal(JSON.parse(store.get(key)).at(-1).requestId, requestId);

  // Push the request out of the look-back: the logs no longer reach it.
  await provider.send("hardhat_mine", ["0x" + (50_100).toString(16)]);
  const pending = await actions.pendingUnwraps(dave, wrapped);
  assert.deepEqual(pending.map(u => u.requestId), [requestId]);
  assert.equal(typeof pending[0].amountHandle, "string");
  assert.ok(store.has(key));

  await actions.finaliseUnwrap(dave, wrapped, {requestId}, steps());
  assert.deepEqual(await actions.pendingUnwraps(dave, wrapped), []);
  assert.equal(store.has(key), false);
  await cleanSlate(dave);
});

test("a remembered unwrap request is kept for 12 blocks after it reads as finished", {skip}, async () => {
  await cleanSlate(dave);
  await actions.wrap(dave, wrapped, {wei: ETHER}, steps());
  let requestId;
  await assert.rejects(
    () => actions.unwrap(rejectingNth(dave, 2), wrapped, {amount: UNIT, ...WRAPPED_UNITS}, steps()),
    err => { requestId = err.requestId; return true; },
  );
  const key = `annuart:unwraps:31337:${wrapped.token}:${dave.address}`.toLowerCase();
  const [entry] = JSON.parse(store.get(key));
  assert.equal(typeof entry.block, "number");

  await actions.finaliseUnwrap(dave, wrapped, {requestId}, steps());
  // A lagging RPC could read zero this early for a live request: not pruned yet.
  assert.deepEqual(await actions.pendingUnwraps(dave, wrapped), []);
  assert.ok(store.has(key));

  await provider.send("hardhat_mine", ["0xc"]);
  assert.deepEqual(await actions.pendingUnwraps(dave, wrapped), []);
  assert.equal(store.has(key), false);

  // An entry with no block number is treated as old.
  store.set(key, JSON.stringify([{requestId, amountHandle: entry.amountHandle}]));
  assert.deepEqual(await actions.pendingUnwraps(dave, wrapped), []);
  assert.equal(store.has(key), false);
  await cleanSlate(dave);
});

// Claim and convert to ETH. Dave again, on the wrapped token: 1 unit a second
// for 1000 seconds out of an endowment of 2000 units.
async function wrappedEnft(session, extra = {}) {
  await actions.wrap(session, wrapped, {wei: 2_000n * UNIT}, steps());
  const {tokenId} = await actions.createEnft(session, wrapped,
    createArgs(session.address, {...WRAPPED_UNITS, ...extra}), steps());
  return tokenId;
}

test("claimToEth pays exactly what was claimed as ETH and leaves the confidential balance alone", {skip}, async () => {
  await cleanSlate(dave);
  const tokenId = await wrappedEnft(dave);
  await increaseTime(100);
  const before = await snapshot(dave);

  const st = steps();
  const result = await actions.claimToEth(dave, wrapped, {tokenId}, st);
  assert.deepEqual(st.ids(), ["claim", "request", "decrypt", "finalise", "withdraw", "mined"]);
  assert.ok(st.finalStates().every(s => s === "done"));
  assert.deepEqual(st.sentLog.map(e => e.id), ["claim", "request", "finalise", "mined"]);
  assert.match(result.hash, /^0x[0-9a-f]{64}$/);
  assert.ok(result.wei >= 100n * UNIT && result.wei <= 115n * UNIT, `paid ${result.wei}`);
  assert.equal(result.note, `${formatAmount(result.wei, 18, {grouping: false})} ETH was sent to your wallet.`);

  assert.equal(await actions.revealDistribution(dave, wrapped, tokenId), 0n);
  assert.equal(await actions.revealBalance(dave, wrapped), before.conf);
  assert.equal(await actions.wethBalance(dave, wrapped), 0n);
  assert.deepEqual(await actions.pendingUnwraps(dave, wrapped), []);
  assert.equal(await actions.ethBalance(dave), before.eth + result.wei - await feesSince(dave, before));
});

test("claimToEth with nothing to claim finishes the empty unwrap and converts nothing", {skip}, async () => {
  await cleanSlate(dave);
  // Payouts have not started, so the claim pays zero.
  const tokenId = await wrappedEnft(dave, {start: BigInt(await chainNow()) + 100_000n});
  const before = await snapshot(dave);

  const st = steps();
  const result = await actions.claimToEth(dave, wrapped, {tokenId}, st);
  assert.deepEqual(st.ids(), ["claim", "request", "decrypt", "finalise", "withdraw", "mined"]);
  assert.equal(st.state("withdraw"), "skipped");
  assert.equal(st.state("mined"), "done");
  assert.equal(result.wei, 0n);
  assert.equal(result.note, "There was nothing to claim, so no ETH was converted.");
  assert.deepEqual(await actions.pendingUnwraps(dave, wrapped), []);
  assert.equal(await actions.revealBalance(dave, wrapped), before.conf);
  assert.equal(await actions.ethBalance(dave), before.eth - await feesSince(dave, before));
});

test("claimToEth with the unwrap request rejected leaves the payout in the wallet as the confidential token", {skip}, async () => {
  await cleanSlate(dave);
  const tokenId = await wrappedEnft(dave);
  await increaseTime(100);
  const before = await snapshot(dave);

  const st = steps();
  await assert.rejects(
    () => actions.claimToEth(rejectingNth(dave, 2), wrapped, {tokenId}, st),
    err => err.requestId === undefined && /^0x[0-9a-f]{64}$/.test(err.sentHash)
      && explain(err) === "You cancelled the request in your wallet.",
  );
  assert.equal(st.state("claim"), "done");
  assert.equal(st.state("request"), "failed");
  const gained = await actions.revealBalance(dave, wrapped) - before.conf;
  assert.ok(gained >= 100n && gained <= 115n, `claimed ${gained}`);
  assert.deepEqual(await actions.pendingUnwraps(dave, wrapped), []);
  // It can still be turned into ETH with the ordinary unwrap.
  await actions.unwrap(dave, wrapped, {amount: gained, ...WRAPPED_UNITS}, steps());
  assert.equal(await actions.revealBalance(dave, wrapped), before.conf);
});

test("claimToEth with finalise rejected carries the request id, and finaliseUnwrap pays the ETH", {skip}, async () => {
  await cleanSlate(dave);
  const tokenId = await wrappedEnft(dave);
  await increaseTime(100);
  const before = await snapshot(dave);

  const st = steps();
  let requestId;
  await assert.rejects(
    () => actions.claimToEth(rejectingNth(dave, 3), wrapped, {tokenId}, st),
    err => { requestId = err.requestId; return explain(err) === "You cancelled the request in your wallet."; },
  );
  assert.match(requestId, /^0x[0-9a-f]{64}$/);
  assert.equal(st.state("finalise"), "failed");
  assert.deepEqual((await actions.pendingUnwraps(dave, wrapped)).map(p => p.requestId), [requestId]);

  const {wei} = await actions.finaliseUnwrap(dave, wrapped, {requestId}, steps());
  assert.ok(wei >= 100n * UNIT && wei <= 115n * UNIT, `paid ${wei}`);
  assert.deepEqual(await actions.pendingUnwraps(dave, wrapped), []);
  assert.equal(await actions.revealBalance(dave, wrapped), before.conf);
  assert.equal(await actions.ethBalance(dave), before.eth + wei - await feesSince(dave, before));
});

test("claimToEth refuses a token that is not wrapped ETH", {skip}, async () => {
  await assert.rejects(() => actions.claimToEth(alice, mock, {tokenId: 1n}, steps()),
    /Only payouts in wrapped ETH can be converted to ETH\./);
});
