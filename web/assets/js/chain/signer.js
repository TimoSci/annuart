// The one place the rest of the app gets a signer from. Imports nothing
// dev-only: the dev login reaches it only through window.__annuartDev, which
// the dev bundle registers (dev.js, loaded only when :dev_wallet is on).
import {createWalletSigner} from "./signer/wallet.js";

export class WrongChainError extends Error {
  constructor(message = "Switch your wallet to the right network.") {
    super(message);
    this.name = "WrongChainError";
  }
}

export function chainInfo() {
  const tag = document.querySelector("meta[name='annuart-chain']");
  const info = tag ? JSON.parse(tag.content) : {};
  return {chainId: info.chainId ?? 0, rpcUrl: info.rpcUrl ?? "", contracts: info.contracts ?? []};
}

export function availableSigners() {
  // chainId 0: the instance has no deployment, so there is nothing to sign for.
  if (chainInfo().chainId === 0) return [];
  const signers = [{id: "wallet", label: "Connect wallet"}];
  if (window.__annuartDev?.createSigner) signers.push({id: "dev", label: "Dev login"});
  return signers;
}

let session = null;
let driver = null;
const listeners = new Set();

const notify = () => listeners.forEach(fn => fn(session));

function setSession(next) {
  session = next;
  notify();
}

function closeDriver() {
  driver?.close?.();
  driver = null;
}

export const current = () => session;

export function onChange(fn) {
  listeners.add(fn);
  return () => listeners.delete(fn);
}

export async function connect(id, opts = {}) {
  closeDriver();
  if (id === "wallet") {
    const d = createWalletSigner();
    const next = await d.connect(opts);
    if (!next) {
      d.close();
      return null;
    }
    driver = d;
    d.onChange(setSession);
    setSession(next);
    return next;
  }
  if (id === "dev") {
    const create = window.__annuartDev?.createSigner;
    if (!create) throw new Error("dev login is not available");
    const next = await create(opts);
    setSession(next);
    return next;
  }
  throw new Error(`unknown signer: ${id}`);
}

export function disconnect() {
  closeDriver();
  if (session !== null) setSession(null);
}

// Resolves to a session on this instance's chain: `s` itself if it is already
// there, or the connected session after asking the wallet to switch. A session
// that is not the connected one (no wallet to ask) is only checked.
export async function ensureChain(s = session) {
  if (!s) throw new Error("not connected");
  const wanted = chainInfo().chainId;
  if (s.chainId === wanted) return s;
  if (s !== session || !driver?.switchChain) throw new WrongChainError();
  try {
    await driver.switchChain(wanted);
  } catch {
    throw new WrongChainError();
  }
  // The wallet announces the new chain through chainChanged, asynchronously.
  for (let i = 0; i < 50 && session?.chainId !== wanted; i++) await new Promise(r => setTimeout(r, 20));
  if (session?.chainId !== wanted) throw new WrongChainError();
  return session;
}
