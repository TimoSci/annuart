import test from "node:test";
import assert from "node:assert/strict";
import {parseHTML} from "linkedom";

// The Wallet hook builds its DOM with `document`; the signer reads the chain
// meta tag from it and window.ethereum / window.__annuartDev from window.
const {document, window} = parseHTML(`<html><head>
  <meta name="annuart-chain" content='{"chainId":31337,"rpcUrl":"http://127.0.0.1:8545","contracts":[]}'>
</head><body><div id="wallet"></div></body></html>`);
globalThis.document = document;
globalThis.window = globalThis;
globalThis.localStorage = {getItem: () => null, setItem() {}, removeItem() {}};

// linkedom's <select> has a read-only value; the hook sets it.
Object.defineProperty(window.HTMLSelectElement?.prototype ?? Object.getPrototypeOf(document.createElement("select")), "value", {
  configurable: true,
  get() { return this.querySelector("option[selected]")?.value ?? this.querySelector("option")?.value ?? ""; },
  set(v) { this.querySelectorAll("option").forEach(o => o.toggleAttribute("selected", o.value === v)); },
});

const {Wallet} = await import("../js/hooks/wallet.js");

function mount() {
  const hook = Object.create(Wallet);
  hook.el = document.getElementById("wallet");
  hook.pushEvent = () => {};
  hook.message = "";
  hook.render();
  return hook;
}

test("with the dev login present, both the wallet button and the dev select show", () => {
  window.__annuartDev = {createSigner: async () => ({}), accounts: ["0x" + "11".repeat(20)]};
  const hook = mount();
  assert.equal(hook.el.querySelector("button.wallet-connect").textContent, "Connect wallet");
  assert.ok(hook.el.querySelector("select.wallet-dev"));
});

test("without the dev login, only the button shows", () => {
  window.__annuartDev = undefined;
  const hook = mount();
  assert.ok(hook.el.querySelector("button.wallet-connect"));
  assert.equal(hook.el.querySelector("select"), null);
});

test("with no injected wallet, the button says so", async () => {
  window.__annuartDev = {createSigner: async () => ({}), accounts: []};
  delete window.ethereum;
  const hook = mount();
  hook.el.querySelector("button.wallet-connect").onclick();
  await new Promise(r => setTimeout(r, 10));
  assert.equal(hook.el.querySelector(".wallet-note").textContent, "No wallet found");
});
