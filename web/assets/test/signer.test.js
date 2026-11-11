import test from "node:test";
import assert from "node:assert/strict";
import {EventEmitter} from "node:events";
import {getAddress} from "ethers";

// Browser globals the signer modules read. The chain config is swapped per test.
let chain = {chainId: 31337, rpcUrl: "http://127.0.0.1:8545", contracts: []};
globalThis.window = globalThis;
globalThis.document = {
  querySelector: sel => sel === "meta[name='annuart-chain']" ? {content: JSON.stringify(chain)} : null,
};
const store = new Map();
globalThis.localStorage = {
  getItem: k => store.get(k) ?? null, setItem: (k, v) => store.set(k, String(v)), removeItem: k => store.delete(k),
};

const signer = await import("../js/chain/signer.js");
const {createDevSigner, accounts} = await import("../js/chain/signer/dev.js");

const ALICE = "0xAb5801a7D398351b8bE11C439e05C5B3259aeC9B";
const BOB = getAddress("0xb0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0");

// A fake EIP-1193 provider: answers the few methods ethers and the signer use.
function fakeEthereum({accounts = [ALICE], chainId = 31337, refuseSwitch = false} = {}) {
  const e = new EventEmitter();
  e.accounts = accounts;
  e.chainId = chainId;
  e.switches = [];
  e.request = async ({method, params}) => {
    switch (method) {
      case "eth_requestAccounts":
      case "eth_accounts": return e.accounts;
      case "eth_chainId": return "0x" + e.chainId.toString(16);
      case "net_version": return String(e.chainId);
      case "wallet_switchEthereumChain": {
        e.switches.push(params[0].chainId);
        if (refuseSwitch) throw Object.assign(new Error("User rejected the request."), {code: 4001});
        e.chainId = parseInt(params[0].chainId, 16);
        e.emit("chainChanged", params[0].chainId);
        return null;
      }
      default: throw new Error(`unexpected ${method}`);
    }
  };
  e.removeListener ??= e.off.bind(e);
  return e;
}

function setup(chainOverride = {}, ethereum = fakeEthereum()) {
  chain = {chainId: 31337, rpcUrl: "http://127.0.0.1:8545", contracts: [], ...chainOverride};
  window.ethereum = ethereum;
  window.__annuartDev = {};
  store.clear();
  return ethereum;
}

test.afterEach(() => signer.disconnect());

test("wallet signer reports address and reacts to accountsChanged", async () => {
  const eth = setup();
  const seen = [];
  const off = signer.onChange(s => seen.push(s?.address ?? null));
  const session = await signer.connect("wallet");
  assert.equal(session.kind, "wallet");
  assert.equal(session.address, ALICE);
  assert.equal(session.chainId, 31337);
  assert.equal(signer.current().address, ALICE);

  const bob = BOB;
  eth.accounts = [bob.toLowerCase()];
  eth.emit("accountsChanged", [bob.toLowerCase()]);
  await new Promise(r => setTimeout(r, 20));
  assert.equal(signer.current().address, bob);
  assert.deepEqual(seen, [ALICE, bob]);
  off();
});

test("accountsChanged([]) disconnects", async () => {
  const eth = setup();
  await signer.connect("wallet");
  const seen = [];
  signer.onChange(s => seen.push(s));
  eth.emit("accountsChanged", []);
  await new Promise(r => setTimeout(r, 20));
  assert.equal(signer.current(), null);
  assert.deepEqual(seen, [null]);
});

test("ensureChain requests a switch and throws WrongChainError when refused", async () => {
  const eth = setup({chainId: 31337}, fakeEthereum({chainId: 1, refuseSwitch: true}));
  await signer.connect("wallet");
  await assert.rejects(() => signer.ensureChain(), err => err instanceof signer.WrongChainError);
  assert.deepEqual(eth.switches, ["0x7a69"]);
});

test("ensureChain switches when the wallet accepts", async () => {
  const eth = setup({chainId: 31337}, fakeEthereum({chainId: 1}));
  await signer.connect("wallet");
  await signer.ensureChain();
  assert.equal(signer.current().chainId, 31337);
});

test("ensureChain resolves when already on the right chain", async () => {
  const eth = setup();
  await signer.connect("wallet");
  await signer.ensureChain();
  assert.deepEqual(eth.switches, []);
});

test("an unconfigured instance (chainId 0) lists no signers", () => {
  setup({chainId: 0, rpcUrl: "", contracts: []});
  window.__annuartDev = {createSigner() {}};
  assert.deepEqual(signer.availableSigners(), []);
});

test("availableSigners lists dev only when the dev bundle registered it", () => {
  setup();
  assert.deepEqual(signer.availableSigners().map(s => s.id), ["wallet"]);
  window.__annuartDev = {createSigner() {}};
  assert.deepEqual(signer.availableSigners().map(s => s.id), ["wallet", "dev"]);
});

test("dev signer refuses a chain other than 31337", async () => {
  setup({chainId: 11155111});
  await assert.rejects(() => createDevSigner({index: 0}), {message: "dev login is only available on chain 31337"});
});

test("dev signer refuses when the provider reports another chain", async () => {
  setup();
  const provider = {getNetwork: async () => ({chainId: 1n})};
  await assert.rejects(() => createDevSigner({index: 0, provider}), {message: "dev login is only available on chain 31337"});
});

test("dev signer derives Hardhat account 0", async () => {
  setup();
  const provider = {getNetwork: async () => ({chainId: 31337n})};
  const s = await createDevSigner({index: 0, provider});
  assert.equal(s.kind, "dev");
  assert.equal(s.address, "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266");
  assert.equal(s.chainId, 31337);
  const s1 = await createDevSigner({index: 1, provider});
  assert.equal(s1.address, "0x70997970C51812dc3A010C7d01b50e0d17dc79C8");
  assert.equal(accounts.length, 5);
  assert.equal(accounts[0], s.address);
  assert.equal(accounts[1], s1.address);
  await assert.rejects(() => createDevSigner({index: 5, provider}), /index/);
});

test("connect('dev') goes through window.__annuartDev and refuses when absent", async () => {
  setup();
  await assert.rejects(() => signer.connect("dev", {index: 0}), /dev login is not available/);
  const fake = {kind: "dev", address: ALICE, signer: {}, provider: {}, chainId: 31337};
  window.__annuartDev = {createSigner: async opts => ({...fake, opts})};
  const s = await signer.connect("dev", {index: 2});
  assert.equal(s.opts.index, 2);
  assert.equal(signer.current().kind, "dev");
});

test("disconnect clears the session and notifies", async () => {
  setup();
  await signer.connect("wallet");
  const seen = [];
  signer.onChange(s => seen.push(s));
  signer.disconnect();
  assert.equal(signer.current(), null);
  assert.deepEqual(seen, [null]);
});

test("ensureChain(session) checks a session that is not the connected one, without switching", async () => {
  const eth = setup({chainId: 31337}, fakeEthereum({chainId: 1}));
  await signer.connect("wallet");
  const dev = {kind: "dev", address: ALICE, signer: {}, provider: {}, chainId: 31337};
  assert.equal(await signer.ensureChain(dev), dev);
  await assert.rejects(() => signer.ensureChain({...dev, chainId: 1}), err => err instanceof signer.WrongChainError);
  assert.deepEqual(eth.switches, []);
});

test("ensureChain returns the connected session once it is on the right chain", async () => {
  setup({chainId: 31337}, fakeEthereum({chainId: 1}));
  const s = await signer.connect("wallet");
  const after = await signer.ensureChain(s);
  assert.equal(after.chainId, 31337);
  assert.equal(after, signer.current());
});
