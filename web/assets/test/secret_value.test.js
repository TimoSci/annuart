import test from "node:test";
import assert from "node:assert/strict";
import {parseHTML} from "linkedom";
import {SecretController} from "../js/hooks/secret_value.js";

const CONTRACT = {label: "mock", nft: "0xnft", token: "0xtok", tokenKind: "mock"};

// `reveal` calls wait for resolve(); a test settles them by hand.
function make() {
  const {document, window} = parseHTML(
    `<html><body><span id="s" data-secret="balance" data-label="mock" data-decimals="2" data-symbol="TKN"></span></body></html>`);
  const el = document.getElementById("s");
  const state = {session: {address: "0xa"}, calls: 0, waiting: []};
  const listeners = new Set();
  const ctl = new SecretController(el, {
    session: () => state.session,
    onSession: fn => { listeners.add(fn); return () => listeners.delete(fn); },
    contract: () => CONTRACT,
    reveal: {
      balance: () => new Promise(resolve => { state.calls += 1; state.waiting.push(resolve); }),
      distribution: async () => 0n,
    },
    target: window,
  });
  const change = session => { state.session = session; listeners.forEach(fn => fn(session)); };
  return {el, ctl, window, state, listeners, change, click: () => el.querySelector("button").click()};
}

const settle = async (t, value = 123456n) => { t.state.waiting.shift()(value); await t.ctl.pending; };

test("a revealed value returns to the placeholder when the session changes", async () => {
  const t = make();
  t.click();
  await settle(t);
  assert.match(t.el.textContent, /1,234\.56 TKN/);
  t.change({address: "0xb"});
  assert.match(t.el.textContent, /•••••/);
  assert.doesNotMatch(t.el.textContent, /TKN/);
});

test("a reveal in flight when the session changes is never shown", async () => {
  const t = make();
  t.click();
  t.change(null);
  await settle(t);
  assert.doesNotMatch(t.el.textContent, /TKN/);
  assert.match(t.el.textContent, /•••••/);
  assert.equal(t.el.querySelector("button").textContent, "Reveal");
});

test("a reveal in flight when annuart:tx resets is never shown", async () => {
  const t = make();
  t.click();
  t.window.dispatchEvent(new t.window.Event("annuart:tx"));
  await settle(t);
  assert.doesNotMatch(t.el.textContent, /TKN/);
  assert.equal(t.el.querySelector("button").textContent, "Reveal");
});

test("a click while a reveal is pending does not start a second decryption", async () => {
  const t = make();
  t.click();
  t.click();
  assert.equal(t.state.calls, 1);
  await settle(t);
  assert.match(t.el.textContent, /TKN/);
});

test("destroy unsubscribes from session changes", () => {
  const t = make();
  assert.equal(t.listeners.size, 1);
  t.ctl.destroy();
  assert.equal(t.listeners.size, 0);
});

test("a transaction's amount is revealed by its hash", async () => {
  const {document, window} = parseHTML(
    `<html><body><span id="s" data-secret="tx" data-tx="0xabc" data-label="mock" data-decimals="2" data-symbol="TKN"></span></body></html>`);
  const el = document.getElementById("s");
  const seen = [];
  const ctl = new SecretController(el, {
    session: () => ({address: "0xa"}),
    contract: () => CONTRACT,
    reveal: {tx: async (_session, contract, hash) => { seen.push([contract.label, hash]); return 250n; }},
    target: window,
  });
  el.querySelector("button").click();
  await ctl.pending;
  assert.deepEqual(seen, [["mock", "0xabc"]]);
  assert.match(el.textContent, /2\.5 TKN/);
});

test("a rate is revealed as the base amount per day, asked for by token id", async () => {
  const {document, window} = parseHTML(
    `<html><body><span id="s" data-secret="rate" data-id="7" data-label="mock" data-decimals="9" data-symbol="cWETH"></span></body></html>`);
  const el = document.getElementById("s");
  const asked = [];
  const ctl = new SecretController(el, {
    session: () => ({address: "0xa"}),
    contract: () => CONTRACT,
    reveal: {rate: async (session, contract, id) => { asked.push(id); return 49710269629n; }},
    target: window,
  });
  el.querySelector("button").click();
  await ctl.pending;
  assert.deepEqual(asked, [7n]);
  assert.match(el.textContent, /0\.999999999 cWETH \/ day at 100%/);
});

test("a rate without a symbol never shows undefined", async () => {
  const {document, window} = parseHTML(
    `<html><body><span id="s" data-secret="rate" data-id="7" data-label="mock" data-decimals="9"></span></body></html>`);
  const el = document.getElementById("s");
  const ctl = new SecretController(el, {
    session: () => ({address: "0xa"}),
    contract: () => CONTRACT,
    reveal: {rate: async () => 49710269629n},
    target: window,
  });
  el.querySelector("button").click();
  await ctl.pending;
  assert.doesNotMatch(el.textContent, /undefined/);
  assert.match(el.textContent, /0\.999999999 \/ day at 100%/);
});
