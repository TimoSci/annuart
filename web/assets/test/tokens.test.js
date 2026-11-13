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
    failed: () => document.dispatchEvent(new window.Event("annuart:tx-failed")),
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

test("shows plain 'Authorised' when no expiry is known", async () => {
  const t = make({reads: {operatorStatus: async () => ({authorised: true, until: null})}});
  await t.ctl.refresh();
  assert.equal(q(t.el, "authorisation").textContent, "Authorised");
});

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

test("a failed unwrap refreshes the card, so its pending request is listed to finish", async () => {
  const requestId = "0x" + "33".repeat(32);
  const data = {pending: []};
  const t = make({
    reads: {pendingUnwraps: async () => data.pending},
    actions: {unwrap: async () => {
      data.pending = [{requestId, amountHandle: "0xh"}];
      throw Object.assign(new Error("could not be decrypted"), {requestId});
    }},
  });
  await t.ctl.pending;
  assert.equal(q(t.el, "unwraps").hasAttribute("hidden"), true);
  type(action(t.el, "unwrap").querySelector("[data-arg=amount]"), "0.5");
  click(runBtn(t.el, "unwrap"));
  await t.statics[2].pending;
  await t.ctl.pending;
  assert.equal(q(t.el, "unwraps").hasAttribute("hidden"), false);
  assert.match(q(t.el, "unwraps").textContent, /Request 0x33333333…333333/);
  assert.equal(t.counts.pendingUnwraps, 2);
});

test("a Finish unwrap that fails keeps its failure on screen when the card refreshes", async () => {
  const requestId = "0x" + "44".repeat(32);
  const t = make({
    reads: {pendingUnwraps: async () => [{requestId, amountHandle: "0xh"}]},
    actions: {finaliseUnwrap: async () => { throw new Error("not decryptable yet"); }},
  });
  await t.ctl.pending;
  const button = q(t.el, "unwraps").querySelector("button[data-role=run]");
  click(button);
  await t.ctl.pendingActions.at(-1);
  await t.ctl.pending;
  assert.equal(t.counts.pendingUnwraps, 2, "the failure refreshed the card");
  const failed = q(t.el, "unwraps").querySelectorAll("li[data-state=failed]");
  assert.equal(failed.length, 1);
  assert.match(failed[0].textContent, /not decryptable yet/);
  assert.equal(q(t.el, "unwraps").querySelectorAll("button[data-role=run]").length, 1);
});

// A wallet on another chain than the instance's. The real reads and the real
// signer are used, so a read that asked the wallet to switch would show here.
test("a wrong-chain wallet: mounting makes no switch request and each card says to switch", async () => {
  const {EventEmitter} = await import("node:events");
  const signer = await import("../js/chain/signer.js");
  const reads = await import("../js/chain/actions.js");
  const ethereum = new EventEmitter();
  const switches = [];
  ethereum.request = async ({method, params}) => {
    switch (method) {
      case "eth_requestAccounts":
      case "eth_accounts": return [ME];
      case "eth_chainId": return "0xaa36a7";
      case "net_version": return "11155111";
      case "wallet_switchEthereumChain": switches.push(params[0].chainId); return null;
      default: throw new Error(`unexpected ${method}`);
    }
  };
  ethereum.removeListener = ethereum.off.bind(ethereum);
  const saved = {window: globalThis.window, document: globalThis.document};
  const meta = {chainId: 31337, rpcUrl: null, contracts: [WRAPPED, MOCK]};
  globalThis.window = {ethereum};
  globalThis.document = {querySelector: sel => (sel === "meta[name='annuart-chain']" ? {content: JSON.stringify(meta)} : null)};
  try {
    const session = await signer.connect("wallet");
    assert.equal(session.chainId, 11155111);
    const line = "Switch your wallet to the right network to see this.";
    for (const kind of ["wrapped", "mock"]) {
      const t = make({kind, session, reads: {
        operatorStatus: reads.operatorStatus, pendingUnwraps: reads.pendingUnwraps,
        wethBalance: reads.wethBalance, ethBalance: reads.ethBalance,
      }});
      await t.ctl.pending;
      assert.equal(q(t.el, "authorisation").textContent, line);
      assert.equal(t.el.textContent.split(line).length - 1, 1, `${kind}: the line is shown once`);
      if (kind === "wrapped") assert.equal(q(t.el, "eth-balance").textContent, "");
    }
    assert.deepEqual(switches, []);
  } finally {
    signer.disconnect();
    globalThis.window = saved.window;
    globalThis.document = saved.document;
  }
});

test("a read failing for another reason keeps its text", async () => {
  const t = make({reads: {operatorStatus: async () => { throw new Error("rpc down"); }}});
  await t.ctl.pending;
  assert.equal(q(t.el, "authorisation").textContent, "Authorisation unavailable.");
});

test("a card shared by two contracts reads and shows each one's authorisation", async () => {
  const labels = ["weth", "auto"];
  const {document, window} = parseHTML(`<html><body><div id="card" data-label="weth" data-labels="weth,auto" data-kind="wrapped" data-symbol="cWETH" data-decimals="9">
    ${labels.map(l => `<span data-role="authorisation" data-contract="${l}"></span>`).join("")}
    <span data-role="eth-balance"></span><div data-role="unwraps" hidden></div><div data-role="weth" hidden></div></div></body></html>`);
  const el = document.getElementById("card");
  const contracts = {weth: WRAPPED, auto: {label: "auto", nft: "0xauto", token: "0xtok", tokenKind: "wrapped"}};
  const asked = [];
  const ctl = new TokensController(el, {
    session: () => SESSION,
    onSession: () => {},
    contract: l => contracts[l],
    reads: {
      operatorStatus: async (s, c) => { asked.push(c.label); return c.label === "auto" ? {authorised: true, until: null} : {authorised: false, until: null}; },
      pendingUnwraps: async () => [], wethBalance: async () => 0n, ethBalance: async () => 0n,
    },
    tx: {session: () => SESSION, contract: l => contracts[l], actions: {}, push() {}, confirm: () => true, announce() {}, failed() {}},
    target: document,
  });
  await ctl.pending;
  assert.deepEqual(asked.sort(), ["auto", "weth"]);
  const line = l => el.querySelector(`[data-role=authorisation][data-contract=${l}]`).textContent;
  assert.equal(line("weth"), "Not authorised");
  assert.equal(line("auto"), "Authorised");
});

test("a single-contract card reads authorisation once", async () => {
  const t = make();
  await t.ctl.pending;
  assert.equal(t.counts.operatorStatus, 1);
});
