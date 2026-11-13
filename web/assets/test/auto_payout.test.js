import test from "node:test";
import assert from "node:assert/strict";
import {parseHTML} from "linkedom";
import {AutoPayoutController} from "../js/hooks/auto_payout.js";
import {ActionError} from "../js/errors.js";

process.env.TZ = "UTC";

const ME = "0x" + "ab".repeat(20);
const SESSION = {address: ME};
const AUTO = {label: "auto", nft: "0xauto", token: "0xtok", tokenKind: "wrapped", nftKind: "auto"};
const NOW = 1_800_000_000;
const ETH = 10n ** 18n;

const STATUS = {
  enabled: true, interval: 86400, fee: 0n, lastRequestAt: null, due: true, pending: null, last: null,
};
const PENDING = {requestId: "0x" + "77".repeat(32), recipient: ME, requester: "0x" + "cd".repeat(20), fee: 0n};

// The markup EnftLive renders for the hook's region.
function make({status = STATUS, owner = false, session = SESSION, actions = {}, confirm = () => true, read} = {}) {
  const {document, window} = parseHTML(`<html><body>
    <div id="auto-payout" data-label="auto" data-token-id="1" data-owner="${owner}"></div></body></html>`);
  const el = document.getElementById("auto-payout");
  const state = {session, status, calls: [], reads: 0, questions: [], answers: confirm};
  const listeners = [];
  const pushed = [];
  const announced = [];
  const wrapped = Object.fromEntries(["triggerPayout", "finishPayout", "setAutoPayout"].map(name => [name, async (s, c, args, onStep) => {
    state.calls.push({name, args, c});
    if (actions[name]) return actions[name](s, c, args, onStep);
    return {hash: "0xh", wei: 0n, feeWei: 0n, paidInWeth: false, note: null};
  }]));
  wrapped.autoPayoutStatus = async (s, c, tokenId) => {
    state.reads += 1;
    assert.equal(tokenId, 1n);
    assert.equal(c, AUTO);
    if (read) return read();
    return state.status;
  };
  const ctl = new AutoPayoutController(el, {
    session: () => state.session,
    onSession: fn => listeners.push(fn),
    contract: l => (l === "auto" ? AUTO : undefined),
    actions: wrapped,
    push: (name, payload) => pushed.push([name, payload]),
    announce: () => { announced.push(1); document.dispatchEvent(new window.Event("annuart:tx")); },
    failed: () => document.dispatchEvent(new window.Event("annuart:tx-failed")),
    confirm: text => { state.questions.push(text); return state.answers(text); },
    now: () => NOW,
    target: document,
  });
  return {ctl, el, document, window, state, pushed, announced,
    setSession: s => { state.session = s; listeners.forEach(fn => fn(s)); }};
}

const q = (el, role) => el.querySelector(`[data-role=${role}]`);
const click = node => node.dispatchEvent(new node.ownerDocument.defaultView.Event("click", {bubbles: true}));
const type = (input, value) => { input.value = value; input.dispatchEvent(new input.ownerDocument.defaultView.Event("input", {bubbles: true})); };
const stateLine = el => q(el, "state").textContent;
// Waits for the click's action and the refresh it causes.
async function settle(t) {
  await Promise.all(t.ctl.pendingActions);
  await t.ctl.pending;
}

test("due: Trigger payout is offered with the gas line, and no Finish", async () => {
  const t = make();
  await t.ctl.pending;
  assert.equal(stateLine(t.el), "A payout can be triggered now.");
  assert.equal(q(t.el, "trigger").textContent, "Trigger payout");
  assert.equal(q(t.el, "finish"), null);
  assert.equal(q(t.el, "trigger-note").textContent, "You pay the transaction fees.");
});

test("due with a fee: the line says what fee the caller receives", async () => {
  const t = make({status: {...STATUS, fee: ETH / 100n}});
  await t.ctl.pending;
  assert.equal(q(t.el, "trigger-note").textContent, "You pay the transaction fees. You receive up to 0.01 ETH as the fee.");
});

test("pending: only Finish payout is offered", async () => {
  const t = make({status: {...STATUS, due: false, lastRequestAt: NOW - 10, pending: PENDING}});
  await t.ctl.pending;
  assert.equal(stateLine(t.el), "A payout is waiting to be finished.");
  assert.equal(q(t.el, "finish").textContent, "Finish payout");
  assert.equal(q(t.el, "trigger"), null);
  assert.equal(q(t.el, "trigger-note"), null);
});

test("too soon: the next possible time and neither button", async () => {
  const last = NOW - 3600;
  const t = make({status: {...STATUS, due: false, lastRequestAt: last}});
  await t.ctl.pending;
  const at = new Date((last + 86400) * 1000).toLocaleString("en-GB", {
    day: "numeric", month: "long", year: "numeric", hour: "2-digit", minute: "2-digit",
  });
  assert.equal(stateLine(t.el), `Next payout possible ${at}.`);
  assert.equal(q(t.el, "trigger"), null);
  assert.equal(q(t.el, "finish"), null);
});

test("off and not the owner: no state line and no buttons", async () => {
  const t = make({status: {...STATUS, enabled: false, due: false}});
  await t.ctl.pending;
  assert.equal(stateLine(t.el), "");
  assert.equal(t.el.querySelectorAll("button").length, 0);
  assert.equal(q(t.el, "set-enabled"), null);
});

test("the owner sees the settings form, prefilled from the chain", async () => {
  const t = make({owner: true, status: {...STATUS, fee: ETH / 50n}});
  await t.ctl.pending;
  assert.equal(q(t.el, "set-enabled").checked, true);
  assert.equal(q(t.el, "set-interval").value, "1");
  assert.equal(q(t.el, "set-interval-unit").value, "days");
  assert.equal(q(t.el, "set-fee").value, "0.02");
  assert.equal(q(t.el, "save").textContent, "Save");
  assert.match(q(t.el, "settings").textContent,
    /Anyone can trigger these payouts, and you receive them as plain ETH\. Each automatic payout amount is public\. If the ENFT ever runs out, that reveals how much it held in total\./);
  assert.match(q(t.el, "settings").textContent, /At most 10% of each payout is ever paid as a fee\./);
  // No input carries a name, so nothing typed can be submitted to the server.
  assert.equal(t.el.querySelectorAll("input[name], select[name]").length, 0);
  // The owner may trigger like anyone else.
  assert.equal(q(t.el, "trigger").textContent, "Trigger payout");
});

test("a 36 hour interval is prefilled in hours, two weeks in weeks", async () => {
  const t = make({owner: true, status: {...STATUS, interval: 36 * 3600}});
  await t.ctl.pending;
  assert.equal(q(t.el, "set-interval").value, "36");
  assert.equal(q(t.el, "set-interval-unit").value, "hours");
  const w = make({owner: true, status: {...STATUS, interval: 14 * 86400}});
  await w.ctl.pending;
  assert.equal(q(w.el, "set-interval").value, "2");
  assert.equal(q(w.el, "set-interval-unit").value, "weeks");
});

test("Save sends the interval in seconds and the fee in wei, and pushes only public fields", async () => {
  const t = make({owner: true});
  await t.ctl.pending;
  type(q(t.el, "set-interval"), "12");
  q(t.el, "set-interval-unit").querySelector("option[value=hours]").selected = true;
  type(q(t.el, "set-fee"), "0.005");
  click(q(t.el, "save"));
  await settle(t);
  const call = t.state.calls.find(c => c.name === "setAutoPayout");
  assert.deepEqual(call.args, {tokenId: 1n, enabled: true, interval: 43200, fee: 5n * 10n ** 15n});
  assert.equal(call.c, AUTO);
  assert.deepEqual(t.state.questions, [], "nothing is asked when it stays on");
  assert.equal(t.pushed.length, 1);
  assert.equal(t.pushed[0][0], "tx:confirmed");
  assert.deepEqual(t.pushed[0][1], {action: "setAutoPayout", label: "auto", tokenId: "1", hash: "0xh"});
});

test("switching on asks first; a declined question sends nothing", async () => {
  const t = make({owner: true, status: {...STATUS, enabled: false, due: false}, confirm: () => false});
  await t.ctl.pending;
  assert.equal(q(t.el, "set-enabled").checked, false);
  q(t.el, "set-enabled").checked = true;
  click(q(t.el, "save"));
  await settle(t);
  assert.deepEqual(t.state.questions, ["Switch automatic payouts on? Each payout amount becomes public."]);
  assert.equal(t.state.calls.length, 0);

  t.state.answers = () => true;
  click(q(t.el, "save"));
  await settle(t);
  assert.equal(t.state.calls.length, 1);
  assert.equal(t.state.calls[0].args.enabled, true);
});

test("switching off asks nothing", async () => {
  const t = make({owner: true});
  await t.ctl.pending;
  q(t.el, "set-enabled").checked = false;
  click(q(t.el, "save"));
  await settle(t);
  assert.deepEqual(t.state.questions, []);
  assert.equal(t.state.calls[0].args.enabled, false);
});

test("an invalid interval or fee shows why and sends nothing", async () => {
  const t = make({owner: true});
  await t.ctl.pending;
  type(q(t.el, "set-interval"), "366");
  click(q(t.el, "save"));
  await settle(t);
  assert.match(q(t.el, "settings").textContent, /The interval must be between 1 hour and 365 days\./);
  type(q(t.el, "set-interval"), "1");
  type(q(t.el, "set-fee"), "1,5");
  click(q(t.el, "save"));
  await settle(t);
  assert.match(q(t.el, "settings").textContent, /Use a period for decimals and no separators/);
  assert.equal(t.state.calls.length, 0);
});

test("a triggerPayout that fails after its request was mined is finished, never requested again", async () => {
  const data = {status: STATUS};
  const t = make({
    read: () => data.status,
    actions: {
      triggerPayout: async (_s, _c, args, onStep) => {
        onStep("requestPayout", "active");
        onStep("requestPayout", "done", {hash: "0xreq"});
        data.status = {...STATUS, due: false, lastRequestAt: NOW, pending: PENDING};
        onStep("decrypt", "active");
        throw Object.assign(new ActionError("The payout amount could not be decrypted. Try finishing the payout again later."),
          {resume: {action: "finishPayout", args: {tokenId: args.tokenId}}});
      },
      finishPayout: async (_s, _c, _args, onStep) => {
        onStep("decrypt", "done");
        onStep("payOut", "done", {hash: "0xpaid"});
        onStep("mined", "done");
        data.status = {...STATUS, due: false, lastRequestAt: NOW, last: {paidAt: NOW, wei: ETH}};
        return {hash: "0xpaid", wei: ETH, feeWei: 0n, paidInWeth: false, note: "1 ETH was paid to the owner."};
      },
    },
  });
  await t.ctl.pending;
  click(q(t.el, "trigger"));
  await settle(t);
  assert.deepEqual(t.state.calls.map(c => c.name), ["triggerPayout"]);
  // The failure stays on screen, offered as a retry, not as a start over.
  assert.match(t.el.querySelector("li[data-state=failed]").textContent, /could not be decrypted/);
  assert.ok(t.el.querySelector("li[data-state=failed] button[data-role=retry]"));
  assert.equal(stateLine(t.el), "A payout is waiting to be finished.");
  assert.equal(q(t.el, "trigger"), null);
  assert.equal(t.el.querySelectorAll("[data-role=finish]").length, 1);

  click(q(t.el, "finish"));
  await settle(t);
  assert.deepEqual(t.state.calls.map(c => c.name), ["triggerPayout", "finishPayout"]);
  assert.deepEqual(t.state.calls[1].args, {tokenId: 1n});
  // The action's note is shown, and the panel reads the chain again.
  assert.match(t.el.textContent, /1 ETH was paid to the owner\./);
  assert.equal(q(t.el, "finish"), null);
  assert.equal(q(t.el, "trigger"), null);
  assert.deepEqual(t.pushed.map(p => p[1].action), ["finishPayout"]);
});

test("a visitor finishing someone else's payout: a failed decrypt is retried with Finish only", async () => {
  const status = {...STATUS, due: false, lastRequestAt: NOW - 60, pending: PENDING};
  let attempts = 0;
  const t = make({
    status,
    actions: {
      finishPayout: async (_s, _c, _args, onStep) => {
        attempts += 1;
        onStep("decrypt", "active");
        if (attempts === 1) throw new ActionError("The payout amount could not be decrypted. Try finishing the payout again later.");
        onStep("decrypt", "done");
        onStep("payOut", "done", {hash: "0xpaid"});
        onStep("mined", "done");
        return {hash: "0xpaid", wei: ETH, feeWei: 0n, paidInWeth: false, note: "1 ETH was paid to the owner."};
      },
    },
  });
  await t.ctl.pending;
  click(q(t.el, "finish"));
  await settle(t);
  const retry = t.el.querySelector("li[data-state=failed] button[data-role=retry]");
  assert.ok(retry, "nothing was sent, so it is a plain Try again");
  assert.equal(retry.textContent, "Try again");
  assert.equal(t.el.querySelector("button[data-role=start-over]"), null);
  click(retry);
  await settle(t);
  assert.deepEqual(t.state.calls.map(c => c.name), ["finishPayout", "finishPayout"]);
  assert.match(t.el.textContent, /1 ETH was paid to the owner\./);
});

test("a successful trigger shows its note, re-reads the status and tells the other hooks", async () => {
  const data = {status: STATUS};
  const t = make({
    read: () => data.status,
    actions: {
      triggerPayout: async () => {
        data.status = {...STATUS, due: false, lastRequestAt: NOW, last: {paidAt: NOW, wei: ETH}};
        return {hash: "0xpaid", wei: ETH, feeWei: 0n, paidInWeth: false, note: "1 ETH was paid to the owner."};
      },
    },
  });
  await t.ctl.pending;
  assert.equal(t.state.reads, 1);
  click(q(t.el, "trigger"));
  await settle(t);
  assert.equal(t.announced.length, 1);
  assert.equal(t.state.reads, 2);
  assert.match(t.el.textContent, /1 ETH was paid to the owner\./);
  assert.match(stateLine(t.el), /^Next payout possible /);
  assert.equal(q(t.el, "trigger"), null);
  assert.deepEqual(Object.keys(t.pushed[0][1]).sort(), ["action", "hash", "label", "tokenId"]);
});

test("no wallet: says to connect one, reads nothing and offers no buttons", async () => {
  const t = make({session: null});
  await t.ctl.pending;
  assert.equal(stateLine(t.el), "Connect a wallet to trigger a payout.");
  assert.equal(t.state.reads, 0);
  assert.equal(t.el.querySelectorAll("button").length, 0);
  t.setSession(SESSION);
  await t.ctl.pending;
  assert.equal(stateLine(t.el), "A payout can be triggered now.");
});

test("a status read that throws says so and offers no buttons", async () => {
  const t = make({owner: true, read: () => { throw new Error("rpc down"); }});
  await t.ctl.pending;
  assert.equal(stateLine(t.el), "Automatic payout status is unavailable.");
  assert.equal([...t.el.querySelectorAll("button")].filter(b => !b.closest("[hidden]")).length, 0);
});

test("the settings form follows data-owner", async () => {
  const t = make();
  await t.ctl.pending;
  assert.equal(q(t.el, "set-enabled"), null);
  t.el.dataset.owner = "true";
  t.ctl.ownerChanged();
  assert.ok(q(t.el, "set-enabled"));
  assert.equal(q(t.el, "settings").hasAttribute("hidden"), false);
  t.el.dataset.owner = "false";
  t.ctl.ownerChanged();
  assert.equal(q(t.el, "settings").hasAttribute("hidden"), true);
});

test("chain data is rendered as text, never HTML", async () => {
  const t = make({status: {...STATUS, due: false, pending: {...PENDING, requester: "<img src=x onerror=alert(1)>"}}});
  await t.ctl.pending;
  assert.equal(t.el.querySelector("img"), null);
});
