// The one place the rest of the app gets a signer from. Imports nothing
// dev-only: the dev login reaches it only through window.__annuartDev, which
// the dev bundle registers (dev.js, loaded only when :dev_wallet is on).
import {createWalletSigner} from "./signer/wallet.js";
import {DEV_CHAIN} from "./chains.js";

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

// The dev login exists on the local chain only, whatever bundle is loaded.
const devLoginAllowed = () => chainInfo().chainId === DEV_CHAIN && Boolean(window.__annuartDev?.createSigner);

export function availableSigners() {
  // chainId 0: the instance has no deployment, so there is nothing to sign for.
  if (chainInfo().chainId === 0) return [];
  const signers = [{id: "wallet", label: "Connect wallet"}];
  if (devLoginAllowed()) signers.push({id: "dev", label: "Dev login"});
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
    const create = devLoginAllowed() ? window.__annuartDev.createSigner : null;
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

// How long ensureChain waits for the wallet to announce the chain it switched to.
export const SWITCH_WAIT_MS = 5000;
const SWITCH_POLL_MS = 20;

// Resolves to `s` (default: the connected session) when it is on this
// instance's chain; otherwise throws WrongChainError. Never asks the wallet for
// anything, so reads that run without a click use this.
export async function requireChain(s = session) {
  if (!s) throw new Error("not connected");
  if (s.chainId !== chainInfo().chainId) throw new WrongChainError();
  return s;
}

// Resolves to a session on this instance's chain: `s` itself if it is already
// there, or the connected session after asking the wallet to switch. A session
// that is not the connected one (no wallet to ask) is only checked. For actions
// the user started with a click.
export async function ensureChain(s = session, {waitMs = SWITCH_WAIT_MS} = {}) {
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
  const deadline = Date.now() + waitMs;
  while (session?.chainId !== wanted && Date.now() < deadline) await new Promise(r => setTimeout(r, SWITCH_POLL_MS));
  if (session?.chainId !== wanted) throw new WrongChainError();
  return session;
}
