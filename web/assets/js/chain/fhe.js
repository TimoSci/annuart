// The FHE client: encrypts amounts, and decrypts handles the user (or anyone,
// for public values) may read. Two implementations sit behind it, both built on
// the FhevmInstance interface the relayer SDK and @fhevm/mock-utils share:
// the dev mock (registered by dev.js as window.__annuartDev.createFhe, chain
// 31337 only) and the relayer SDK (loaded on first use from /vendor/relayer-sdk/).
// This module imports nothing dev-only.
import {getAddress, hexlify} from "ethers";

export const ZERO_HANDLE = "0x" + "00".repeat(32);

const DEV_CHAIN = 31337;
const DECRYPT_DAYS = 1;
const DAY = 86400;
// Re-sign a little before the user-decryption permit expires.
const EXPIRY_MARGIN = 60;

const isZero = handle => String(handle).toLowerCase() === ZERO_HANDLE;
const clearOf = (values, handle) => values[handle] ?? values[String(handle).toLowerCase()];

// Wraps a FhevmInstance as the app's Fhe. Each Fhe keeps, in memory, one
// keypair and EIP-712 signature per (user, sorted contract set), so repeated
// reveals do not ask the wallet to sign again.
export function fheFromInstance(instance) {
  const permits = new Map();

  function permitFor(session, contracts) {
    const key = `${session.address.toLowerCase()}|${contracts.join(",").toLowerCase()}`;
    const now = Math.floor(Date.now() / 1000);
    const cached = permits.get(key);
    if (cached && now < cached.expires) return cached.permit;

    const permit = (async () => {
      const {publicKey, privateKey} = instance.generateKeypair();
      const eip712 = instance.createEIP712(publicKey, contracts, now, DECRYPT_DAYS);
      const signature = await session.signer.signTypedData(
        eip712.domain,
        {[eip712.primaryType]: eip712.types[eip712.primaryType]},
        eip712.message,
      );
      return {publicKey, privateKey, signature, start: now};
    })();
    const entry = {permit, expires: now + DECRYPT_DAYS * DAY - EXPIRY_MARGIN};
    permits.set(key, entry);
    // A refused signature must not stick: the next reveal asks again.
    permit.catch(() => { if (permits.get(key) === entry) permits.delete(key); });
    return permit;
  }

  return {
    async encrypt64(contractAddress, userAddress, value) {
      const {handles, inputProof} = await instance.createEncryptedInput(contractAddress, userAddress).add64(value).encrypt();
      return {handle: hexlify(handles[0]), inputProof: hexlify(inputProof)};
    },

    async userDecrypt(pairs, session) {
      const out = new Map();
      const wanted = [];
      for (const {handle, contractAddress} of pairs) {
        if (isZero(handle)) out.set(handle, 0n);
        else wanted.push({handle, contractAddress: getAddress(contractAddress)});
      }
      if (wanted.length === 0) return out;

      const contracts = [...new Set(wanted.map(p => p.contractAddress))]
        .sort((a, b) => a.toLowerCase().localeCompare(b.toLowerCase()));
      const {publicKey, privateKey, signature, start} = await permitFor(session, contracts);
      const values = await instance.userDecrypt(
        wanted, privateKey, publicKey, signature, contracts, session.address, start, DECRYPT_DAYS,
      );
      for (const {handle} of wanted) out.set(handle, BigInt(clearOf(values, handle)));
      return out;
    },

    async publicDecrypt(handles) {
      const {clearValues, decryptionProof} = await instance.publicDecrypt(handles);
      const values = new Map(handles.map(h => [h, BigInt(clearOf(clearValues, h))]));
      return {values, proof: decryptionProof};
    },
  };
}

// One client per (implementation, chain) for the page's lifetime.
const clients = new Map();

export function getFhe(session) {
  const createMock = session.chainId === DEV_CHAIN ? window.__annuartDev?.createFhe : undefined;
  const key = `${createMock ? "mock" : "relayer"}:${session.chainId}`;
  let client = clients.get(key);
  if (!client) {
    client = createMock
      ? Promise.resolve().then(() => createMock(session))
      : import("./fhe/relayer.js").then(m => m.createRelayerFhe(session));
    clients.set(key, client);
    // A failed set-up is retried on the next call.
    client.catch(() => { if (clients.get(key) === client) clients.delete(key); });
  }
  return client;
}
