import test from "node:test";
import assert from "node:assert/strict";
import {parseHTML} from "linkedom";
import {TokensController} from "../js/hooks/tokens.js";
import {TxActionController} from "../js/hooks/tx_action.js";
import {checkWrapFunds} from "../js/chain/actions.js";
import {ActionError, explain} from "../js/errors.js";

process.env.TZ = "UTC";

const ME = "0x" + "ab".repeat(20);
const SESSION = {address: ME};
const WRAPPED = {label: "weth", nft: "0xnft", token: "0xtok", tokenKind: "wrapped", underlying: "0xweth"};
const MOCK = {label: "mock", nft: "0xnft", token: "0xtok", tokenKind: "mock"};

// The static markup TokensLive renders for one card.
function cardHtml({kind, label, decimals, symbol}) {
  const tx = (action, text, inner = "") =>
    `<div class="tx" data-action="${action}" data-label="${label}" data-decimals="${decimals}" data-symbol="${symbol}">${inner}<button type="button" data-role="run">${text}</button><ol class="steps"></ol></div>`;
  return `<div id="card" data-label="${label}" data-kind="${kind}" data-symbol="${symbol}" data-decimals="${decimals}">
    <span data-role="authorisation"></span>
    ${tx("authorise", "Authorise")}
    ${kind === "mock" ? tx("faucet", "Get test tokens", '<input type="hidden" data-arg="amount" value="1000">') : ""}
    ${kind === "wrapped" ? `<span data-role="eth-balance"></span>
      ${tx("wrap", "Wrap", '<input type="text" data-arg="wei">')}
      ${tx("unwrap", "Unwrap", '<input type="text" data-arg="amount">')}
      <div data-role="unwraps" hidden></div><div data-role="weth" hidden></div>` : ""}
  </div>`;
}

function make({kind = "wrapped", decimals = 9, symbol = "cWETH", contract, reads = {}, session = SESSION, actions = {}} = {}) {
  const label = contract?.label ?? (kind === "wrapped" ? "weth" : "mock");
  const {document, window} = parseHTML(`<html><body>${cardHtml({kind, label, decimals, symbol})}</body></html>`);
  const el = document.getElementById("card");
  const state = {session, calls: [], reads: {
    operatorStatus: async () => ({authorised: false, until: null}),
    pendingUnwraps: async () => [],
    wethBalance: async () => 0n,
    ethBalance: async () => 0n,
    ...reads,
  }};
  const counts = {};
  const reading = Object.fromEntries(Object.entries(state.reads).map(([name, fn]) => [name, async (...a) => {
    counts[name] = (counts[name] ?? 0) + 1;
    return fn(...a);
  }]));
  const pushed = [];
  const announced = [];
  const listeners = [];
  const c = contract ?? (kind === "wrapped" ? WRAPPED : MOCK);
  const wrapped = Object.fromEntries(["authorise", "faucet", "wrap", "unwrap", "finaliseUnwrap", "withdrawWeth"].map(name => [name, async (s, ct, args) => {
    state.calls.push({name, args, c: ct});
    if (actions[name]) return actions[name](s, ct, args);
    return {hash: "0xh"};
  }]));
  const tx = {
    session: () => state.session,
    contract: l => (l === c.label ? c : undefined),
    actions: wrapped,
    push: (name, payload) => pushed.push([name, payload]),
    confirm: () => true,
    announce: () => { announced.push(1); document.dispatchEvent(new window.Event("annuart:tx")); },
  };
  // The static actions are mounted by LiveView; here a controller stands in.
  const statics = [...el.querySelectorAll(".tx")].map(node => new TxActionController(node, tx));
  const ctl = new TokensController(el, {
    session: () => state.session,
    onSession: fn => listeners.push(fn),
    contract: tx.contract,
    reads: reading,
    tx,
    target: document,
  });
  return {ctl, el, document, window, state, counts, pushed, announced, statics, tx,
    setSession: s => { state.session = s; listeners.forEach(fn => fn(s)); }};
}

const q = (el, role) => el.querySelector(`[data-role=${role}]`);
const type = (input, value) => { input.value = value; input.dispatchEvent(new input.ownerDocument.defaultView.Event("input", {bubbles: true})); };
const click = node => node.dispatchEvent(new node.ownerDocument.defaultView.Event("click", {bubbles: true}));
const action = (el, name) => el.querySelector(`.tx[data-action=${name}]`);
const runBtn = (el, name) => action(el, name).querySelector("button[data-role=run]");

test("shows 'Authorised until' with the expiry date", async () => {
  const t = make({reads: {operatorStatus: async () => ({authorised: true, until: 1794441600})}});
  await t.ctl.pending;
  const expected = new Date(1794441600 * 1000).toLocaleDateString("en-GB", {day: "numeric", month: "long", year: "numeric"});
  assert.equal(q(t.el, "authorisation").textContent, `Authorised until ${expected}`);
  assert.match(expected, /^12 November 2026$/);
});

test("shows 'Not authorised' and the Authorise button", async () => {
  const t = make();
  await t.ctl.pending;
  assert.equal(q(t.el, "authorisation").textContent, "Not authorised");
  assert.equal(runBtn(t.el, "authorise").textContent, "Authorise");
  click(runBtn(t.el, "authorise"));
  await t.statics[0].pending;
  assert.equal(t.state.calls[0].name, "authorise");
});

test("wrap converts the ETH amount to wei and calls actions.wrap", async () => {
  const t = make();
  await t.ctl.pending;
  const input = action(t.el, "wrap").querySelector("[data-arg=wei]");
  type(input, "0.5");
  assert.equal(action(t.el, "wrap").querySelector(".amount-echo").textContent, "= 0.5 ETH");
  click(runBtn(t.el, "wrap"));
  await t.statics[1].pending;
  const call = t.state.calls.find(c => c.name === "wrap");
  assert.equal(call.args.wei, 500000000000000000n);
  assert.equal(call.c, WRAPPED);
});

test("wrap shows the explained message for an invalid ETH amount", async () => {
  const t = make();
  await t.ctl.pending;
  type(action(t.el, "wrap").querySelector("[data-arg=wei]"), "0.1234567890123456789");
  assert.equal(action(t.el, "wrap").querySelector(".amount-echo").textContent, "Use at most 18 decimal places.");
  click(runBtn(t.el, "wrap"));
  await t.statics[1].pending;
  assert.equal(t.state.calls.length, 0);
});

test("wrap refuses more ETH than the wallet holds", () => {
  const msg = "You do not have that much ETH.";
  assert.throws(() => checkWrapFunds(11n, 5n, 5n), err => err instanceof ActionError && explain(err) === msg);
  // WETH already held counts, and exactly everything is allowed.
  assert.doesNotThrow(() => checkWrapFunds(10n, 5n, 5n));
  assert.doesNotThrow(() => checkWrapFunds(3n, 5n, 0n));
});

test("unwrap echoes the token amount and calls actions.unwrap in base units", async () => {
  const t = make();
  await t.ctl.pending;
  type(action(t.el, "unwrap").querySelector("[data-arg=amount]"), "0.5");
  assert.equal(action(t.el, "unwrap").querySelector(".amount-echo").textContent, "= 0.5 cWETH");
  click(runBtn(t.el, "unwrap"));
  await t.statics[2].pending;
  assert.equal(t.state.calls.find(c => c.name === "unwrap").args.amount, 500000000n);
});

test("get test tokens requests 1000 whole tokens in base units", async () => {
  const t = make({kind: "mock", decimals: 6, symbol: "TKN"});
  await t.ctl.pending;
  click(runBtn(t.el, "faucet"));
  await t.statics[1].pending;
  assert.equal(t.state.calls.find(c => c.name === "faucet").args.amount, 1000n * 10n ** 6n);
});

test("shows the wallet's ETH balance on a wrapped card only", async () => {
  const t = make({reads: {ethBalance: async () => 1_500_000_000_000_000_000n}});
  await t.ctl.pending;
  assert.equal(q(t.el, "eth-balance").textContent, "1.5 ETH");
  const m = make({kind: "mock", decimals: 6, symbol: "TKN"});
  await m.ctl.pending;
  assert.equal(m.counts.ethBalance, undefined);
  assert.equal(m.counts.pendingUnwraps, undefined);
  assert.equal(m.counts.wethBalance, undefined);
});

test("lists each pending unwrap with a Finish unwrap action and the note", async () => {
  const ids = ["0x" + "11".repeat(32), "0x" + "22".repeat(32)];
  const t = make({reads: {pendingUnwraps: async () => ids.map(requestId => ({requestId, amountHandle: "0xh"}))}});
  await t.ctl.pending;
  const section = q(t.el, "unwraps");
  assert.equal(section.hasAttribute("hidden"), false);
  assert.match(section.textContent, /Unfinished unwraps/);
  assert.match(section.textContent, /These were requested but not completed\. Finishing one returns its amount as ETH\./);
  const buttons = [...section.querySelectorAll("button[data-role=run]")];
  assert.deepEqual(buttons.map(b => b.textContent), ["Finish unwrap", "Finish unwrap"]);
  click(buttons[1]);
  await t.ctl.pendingActions.at(-1);
  const call = t.state.calls.find(c => c.name === "finaliseUnwrap");
  assert.deepEqual(call.args, {requestId: ids[1]});
  assert.equal(call.c, WRAPPED);
});

test("hides the unfinished unwraps section when there are none", async () => {
  const t = make();
  await t.ctl.pending;
  assert.equal(q(t.el, "unwraps").hasAttribute("hidden"), true);
  assert.equal(q(t.el, "unwraps").textContent, "");
});

test("shows the WETH line only when the balance is above zero", async () => {
  const none = make();
  await none.ctl.pending;
  assert.equal(q(none.el, "weth").hasAttribute("hidden"), true);
  assert.equal(q(none.el, "weth").textContent, "");

  const t = make({reads: {wethBalance: async () => 250_000_000_000_000_000n}});
  await t.ctl.pending;
  const line = q(t.el, "weth");
  assert.equal(line.hasAttribute("hidden"), false);
  assert.match(line.textContent, /WETH in your wallet: 0\.25 WETH/);
  assert.match(line.textContent, /Left over from an interrupted wrap or unwrap\./);
  const button = line.querySelector("button[data-role=run]");
  assert.equal(button.textContent, "Convert to ETH");
  click(button);
  await t.ctl.pendingActions.at(-1);
  const call = t.state.calls.find(c => c.name === "withdrawWeth");
  assert.deepEqual(call.args, {wei: 250_000_000_000_000_000n});
});

test("refreshes balances, authorisation, unwraps and WETH after an action completes", async () => {
  const data = {authorised: false, eth: 5n * 10n ** 18n, weth: 10n ** 18n, pending: [{requestId: "0x" + "11".repeat(32), amountHandle: "0xh"}]};
  const t = make({reads: {
    operatorStatus: async () => ({authorised: data.authorised, until: data.authorised ? 1794441600 : null}),
    ethBalance: async () => data.eth,
    wethBalance: async () => data.weth,
    pendingUnwraps: async () => data.pending,
  }});
  await t.ctl.pending;
  assert.equal(q(t.el, "authorisation").textContent, "Not authorised");
  assert.equal(q(t.el, "weth").hasAttribute("hidden"), false);
  // The action changes what is on chain; completing it refreshes the card.
  data.authorised = true; data.eth = 4n * 10n ** 18n; data.weth = 0n; data.pending = [];
  click(runBtn(t.el, "authorise"));
  await t.statics[0].pending;
  await t.ctl.pending;
  assert.match(q(t.el, "authorisation").textContent, /^Authorised until /);
  assert.equal(q(t.el, "eth-balance").textContent, "4 ETH");
  assert.equal(q(t.el, "weth").hasAttribute("hidden"), true);
  assert.equal(q(t.el, "unwraps").hasAttribute("hidden"), true);
  assert.equal(t.counts.operatorStatus, 2);
  assert.equal(t.pushed.length, 1);
  assert.deepEqual(Object.keys(t.pushed[0][1]).sort(), ["action", "hash", "label", "tokenId"]);
});

test("a failing read leaves the other fields working", async () => {
  const t = make({reads: {
    operatorStatus: async () => { throw new Error("rpc down"); },
    ethBalance: async () => 10n ** 18n,
  }});
  await t.ctl.pending;
  assert.equal(q(t.el, "authorisation").textContent, "Authorisation unavailable.");
  assert.equal(q(t.el, "eth-balance").textContent, "1 ETH");
});

test("reads again when the wallet changes and clears when it disconnects", async () => {
  const t = make({reads: {operatorStatus: async () => ({authorised: true, until: 1794441600})}});
  await t.ctl.pending;
  t.setSession(null);
  await t.ctl.pending;
  assert.equal(q(t.el, "authorisation").textContent, "");
  assert.equal(q(t.el, "eth-balance").textContent, "");
  t.setSession(SESSION);
  await t.ctl.pending;
  assert.match(q(t.el, "authorisation").textContent, /^Authorised until/);
});

test("chain data is rendered as text, never HTML", async () => {
  const evil = "<img src=x onerror=alert(1)>";
  const t = make({reads: {pendingUnwraps: async () => [{requestId: evil, amountHandle: "0x"}]}});
  await t.ctl.pending;
  assert.equal(t.el.querySelector("img"), null);
});
