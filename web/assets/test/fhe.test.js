import test from "node:test";
import assert from "node:assert/strict";

// Browser globals chain/fhe.js and chain/fhe/relayer.js read.
let chain = {chainId: 11155111, rpcUrl: "https://rpc.example", contracts: []};
globalThis.window = globalThis;
const appended = [];
globalThis.document = {
  querySelector: sel => sel === "meta[name='annuart-chain']" ? {content: JSON.stringify(chain)} : null,
  createElement: tag => ({tag}),
  head: {
    // A fake <script> load: record the element, run the "bundle", then fire onload.
    appendChild(el) {
      appended.push(el);
      queueMicrotask(() => {
        window.relayerSDK = fakeSdk;
        el.onload?.();
      });
      return el;
    },
  },
};

const {fheFromInstance, getFhe, ZERO_HANDLE} = await import("../js/chain/fhe.js");
const {createRelayerFhe} = await import("../js/chain/fhe/relayer.js");

const NFT = "0x1111111111111111111111111111111111111111";
const TOKEN = "0x2222222222222222222222222222222222222222";
const USER = "0x3333333333333333333333333333333333333333";
const H1 = "0x" + "ab".repeat(32);
const H2 = "0x" + "cd".repeat(32);

// A fake FhevmInstance (the interface the mock and the relayer SDK share).
function fakeInstance() {
  const calls = {keypairs: 0, eip712: [], userDecrypt: [], publicDecrypt: [], encrypt: []};
  return {
    calls,
    generateKeypair() {
      calls.keypairs++;
      return {publicKey: `pub${calls.keypairs}`, privateKey: `priv${calls.keypairs}`};
    },
    createEIP712(publicKey, contracts, start, days) {
      calls.eip712.push({publicKey, contracts, start, days});
      return {
        domain: {name: "Decryption"},
        primaryType: "UserDecryptRequestVerification",
        types: {UserDecryptRequestVerification: [{name: "publicKey", type: "bytes"}], EIP712Domain: []},
        message: {publicKey, contracts},
      };
    },
    async userDecrypt(pairs, privateKey, publicKey, signature, contracts, user, start, days) {
      calls.userDecrypt.push({pairs, privateKey, publicKey, signature, contracts, user, start, days});
      return Object.fromEntries(pairs.map((p, i) => [p.handle, BigInt(i + 7)]));
    },
    async publicDecrypt(handles) {
      calls.publicDecrypt.push(handles);
      return {clearValues: Object.fromEntries(handles.map((h, i) => [h, BigInt(i + 40)])), decryptionProof: "0xfeed"};
    },
    createEncryptedInput(contract, user) {
      const values = [];
      calls.encrypt.push({contract, user, values});
      return {
        add64(v) { values.push(v); return this; },
        async encrypt() { return {handles: [new Uint8Array(32).fill(0xab)], inputProof: new Uint8Array([1, 2, 3])}; },
      };
    },
  };
}

// A signer that counts how often it is asked to sign.
function countingSession(address = USER) {
  const signed = [];
  return {
    signed,
    session: {
      address,
      chainId: 31337,
      signer: {
        async signTypedData(domain, types, message) {
          signed.push({domain, types, message});
          return `0xsig${signed.length}`;
        },
      },
    },
  };
}

test("userDecrypt signs once and reuses keypair and signature for later reveals", async () => {
  const inst = fakeInstance();
  const fhe = fheFromInstance(inst);
  const {session, signed} = countingSession();
  const first = await fhe.userDecrypt([{handle: H1, contractAddress: NFT}], session);
  const second = await fhe.userDecrypt([{handle: H2, contractAddress: NFT}], session);
  assert.equal(signed.length, 1);
  assert.equal(inst.calls.keypairs, 1);
  assert.equal(first.get(H1), 7n);
  assert.equal(second.get(H2), 7n);
  assert.equal(inst.calls.userDecrypt.length, 2);
  assert.equal(inst.calls.userDecrypt[0].signature, "0xsig1");
  assert.equal(inst.calls.userDecrypt[1].signature, "0xsig1");
  assert.equal(inst.calls.userDecrypt[1].privateKey, "priv1");
  assert.equal(inst.calls.userDecrypt[1].user, USER);
  // The typed data signed is the EIP-712 request without the EIP712Domain entry.
  assert.deepEqual(Object.keys(signed[0].types), ["UserDecryptRequestVerification"]);
});

test("the cache key is the address and the sorted contract set", async () => {
  const inst = fakeInstance();
  const fhe = fheFromInstance(inst);
  const {session, signed} = countingSession();
  await fhe.userDecrypt([{handle: H1, contractAddress: NFT}, {handle: H2, contractAddress: TOKEN}], session);
  await fhe.userDecrypt([{handle: H2, contractAddress: TOKEN}, {handle: H1, contractAddress: NFT}], session);
  assert.equal(signed.length, 1);
  await fhe.userDecrypt([{handle: H1, contractAddress: NFT}], session);
  assert.equal(signed.length, 2);
  const other = countingSession("0x4444444444444444444444444444444444444444");
  await fhe.userDecrypt([{handle: H1, contractAddress: NFT}], other.session);
  assert.equal(other.signed.length, 1);
  assert.equal(signed.length, 2);
});

test("the zero handle decrypts to 0n with no signing and no request", async () => {
  const inst = fakeInstance();
  const fhe = fheFromInstance(inst);
  const {session, signed} = countingSession();
  assert.equal(ZERO_HANDLE, "0x" + "00".repeat(32));
  const out = await fhe.userDecrypt([{handle: ZERO_HANDLE, contractAddress: NFT}], session);
  assert.equal(out.get(ZERO_HANDLE), 0n);
  assert.equal(signed.length, 0);
  assert.equal(inst.calls.keypairs, 0);
  assert.equal(inst.calls.userDecrypt.length, 0);

  // Mixed: only the non-zero handle is sent.
  const mixed = await fhe.userDecrypt([{handle: ZERO_HANDLE, contractAddress: NFT}, {handle: H1, contractAddress: NFT}], session);
  assert.equal(mixed.get(ZERO_HANDLE), 0n);
  assert.equal(mixed.get(H1), 7n);
  assert.deepEqual(inst.calls.userDecrypt[0].pairs, [{handle: H1, contractAddress: NFT}]);
});

test("encrypt64 returns hex handle and proof for the given contract and user", async () => {
  const inst = fakeInstance();
  const fhe = fheFromInstance(inst);
  const out = await fhe.encrypt64(NFT, USER, 123n);
  assert.deepEqual(inst.calls.encrypt, [{contract: NFT, user: USER, values: [123n]}]);
  assert.equal(out.handle, H1);
  assert.equal(out.inputProof, "0x010203");
});

test("publicDecrypt returns values by handle and the decryption proof", async () => {
  const inst = fakeInstance();
  const fhe = fheFromInstance(inst);
  const {values, proof} = await fhe.publicDecrypt([H1, H2]);
  assert.equal(values.get(H1), 40n);
  assert.equal(values.get(H2), 41n);
  assert.equal(proof, "0xfeed");
});

let fakeSdk;
function installFakeSdk() {
  const seen = {init: [], create: []};
  fakeSdk = {
    SepoliaConfig: {chainId: 11155111, relayerUrl: "https://relayer.example"},
    MainnetConfig: {chainId: 1, relayerUrl: "https://relayer.mainnet.example"},
    async initSDK(opts) { seen.init.push(opts); return true; },
    async createInstance(config) { seen.create.push(config); return fakeInstance(); },
  };
  return seen;
}

test("the relayer client loads the vendored bundle once, with explicit WASM URLs", async () => {
  chain = {chainId: 11155111, rpcUrl: "https://rpc.example", contracts: []};
  delete window.relayerSDK;
  appended.length = 0;
  const seen = installFakeSdk();
  const session = {address: USER, chainId: 11155111};
  const [a, b] = await Promise.all([createRelayerFhe(session), createRelayerFhe(session)]);
  assert.equal(appended.length, 1);
  assert.equal(appended[0].src, "/vendor/relayer-sdk/relayer-sdk-js.umd.js");
  assert.deepEqual(seen.init, [{tfheParams: "/vendor/relayer-sdk/tfhe_bg.wasm", kmsParams: "/vendor/relayer-sdk/kms_lib_bg.wasm"}]);
  assert.deepEqual(seen.create, [{chainId: 11155111, relayerUrl: "https://relayer.example", network: "https://rpc.example"}]);
  assert.equal(a, b);
  assert.equal(typeof a.encrypt64, "function");
  assert.equal(typeof a.userDecrypt, "function");
  assert.equal(typeof a.publicDecrypt, "function");
});

test("the relayer client refuses a chain the SDK has no config for", async () => {
  chain = {chainId: 31337, rpcUrl: "http://127.0.0.1:8545", contracts: []};
  installFakeSdk();
  await assert.rejects(() => createRelayerFhe({address: USER, chainId: 31337}), /not available on chain 31337/);
});

test("getFhe uses the dev mock on 31337 when the dev bundle registered it, else the relayer", async () => {
  chain = {chainId: 31337, rpcUrl: "http://127.0.0.1:8545", contracts: []};
  const mock = fheFromInstance(fakeInstance());
  let created = 0;
  window.__annuartDev = {createFhe: async () => { created++; return mock; }};
  const s = {address: USER, chainId: 31337};
  assert.equal(await getFhe(s), mock);
  assert.equal(await getFhe(s), mock);
  assert.equal(created, 1);

  // Without the dev bundle, 31337 goes to the relayer, which has no config for it.
  window.__annuartDev = {};
  installFakeSdk();
  await assert.rejects(() => getFhe(s), /not available on chain 31337/);

  // Sepolia goes to the relayer even when the dev bundle is present.
  chain = {chainId: 11155111, rpcUrl: "https://rpc.example", contracts: []};
  window.__annuartDev = {createFhe: async () => { throw new Error("must not be called"); }};
  const sepolia = await getFhe({address: USER, chainId: 11155111});
  assert.equal(typeof sepolia.userDecrypt, "function");
});
