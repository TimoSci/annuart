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
function make({status = STATUS, owner = false, session = SESSION, actions = {}, confirm = () => true, read, now = NOW} = {}) {
  const {document, window} = parseHTML(`<html><body>
    <div id="auto-payout" data-label="auto" data-token-id="1" data-owner="${owner}" data-rev="r1"></div></body></html>`);
  const el = document.getElementById("auto-payout");
  const state = {session, status, calls: [], reads: 0, questions: [], answers: confirm, now, timers: []};
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
    now: () => state.now,
    schedule: (fn, ms) => { const t = {fn, ms, cancelled: false}; state.timers.push(t); return t; },
    cancel: t => { t.cancelled = true; },
    target: document,
  });
  return {ctl, el, document, window, state, pushed, announced,
    setSession: s => { state.session = s; listeners.forEach(fn => fn(s)); }};
}

const q = (el, role) => el.querySelector(`[data-role=${role}]`);
const click = node => node.dispatchEvent(new node.ownerDocument.defaultView.Event("click", {bubbles: true}));
const type = (input, value) => { input.value = value; input.dispatchEvent(new input.ownerDocument.defaultView.Event("input", {bubbles: true})); };
const stateLine = el => q(el, "state").textContent;
const change = node => node.dispatchEvent(new node.ownerDocument.defaultView.Event("change", {bubbles: true}));
const liveTimers = t => t.state.timers.filter(x => !x.cancelled);
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
  change(q(t.el, "set-interval-unit"));
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
  change(q(t.el, "set-enabled"));
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
  change(q(t.el, "set-enabled"));
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
  t.ctl.attributesChanged();
  assert.ok(q(t.el, "set-enabled"));
  assert.equal(q(t.el, "settings").hasAttribute("hidden"), false);
  t.el.dataset.owner = "false";
  t.ctl.attributesChanged();
  assert.equal(q(t.el, "settings").hasAttribute("hidden"), true);
  // A change of owner alone is drawn from the status already read.
  assert.equal(t.state.reads, 1);
});

test("an action's note is shown as text, never as HTML", async () => {
  const evil = "<img src=x onerror=alert(1)>";
  const t = make({actions: {triggerPayout: async () => ({hash: "0xh", wei: 1n, feeWei: 0n, paidInWeth: false, note: evil})}});
  await t.ctl.pending;
  click(q(t.el, "trigger"));
  await settle(t);
  assert.equal(t.el.querySelector("img"), null);
  assert.match(t.el.textContent, /<img src=x onerror=alert\(1\)>/);
});

test("a 129600 second interval is prefilled as 36 hours", async () => {
  const t = make({owner: true, status: {...STATUS, interval: 129600}});
  await t.ctl.pending;
  assert.equal(q(t.el, "set-interval").value, "36");
  assert.equal(q(t.el, "set-interval-unit").value, "hours");
  assert.equal(q(t.el, "interval-note").textContent, "");
});

test("an interval of no whole hours leaves the box empty and says what it is", async () => {
  const t = make({owner: true, status: {...STATUS, interval: 5400}});
  await t.ctl.pending;
  assert.equal(q(t.el, "set-interval").value, "");
  assert.equal(q(t.el, "interval-note").textContent, "The interval is 5400 seconds.");
  click(q(t.el, "save"));
  await settle(t);
  assert.equal(t.state.calls.length, 0, "a blank interval is refused, not guessed");
});

test("pending, then finished elsewhere: no dead Try again is left", async () => {
  const data = {status: {...STATUS, due: false, lastRequestAt: NOW - 60, pending: PENDING}};
  const t = make({
    read: () => data.status,
    actions: {
      finishPayout: async (_s, _c, _args, onStep) => {
        onStep("decrypt", "active");
        // Someone else finished it in the meantime.
        data.status = {...STATUS, due: false, lastRequestAt: NOW - 60, last: {paidAt: NOW, wei: ETH}};
        throw new ActionError("This payout has already been finished.");
      },
    },
  });
  await t.ctl.pending;
  click(q(t.el, "finish"));
  await settle(t);
  assert.equal(t.el.querySelector("button[data-role=retry]"), null);
  assert.equal(t.el.querySelector("li[data-state=failed]"), null);
  assert.equal(q(t.el, "finish"), null);
  assert.equal(t.el.querySelectorAll("button").length, 0);
  assert.equal(q(t.el, "finished-note").textContent, "This payout has already been finished.");
  assert.match(stateLine(t.el), /^Next payout possible /);
});

test("a trigger left finishing, then finished elsewhere: the next read clears it", async () => {
  const data = {status: STATUS};
  const t = make({
    read: () => data.status,
    actions: {
      triggerPayout: async (_s, _c, args, onStep) => {
        onStep("requestPayout", "done", {hash: "0xreq"});
        data.status = {...STATUS, due: false, lastRequestAt: NOW, pending: PENDING};
        onStep("decrypt", "active");
        throw Object.assign(new ActionError("not decryptable yet"), {resume: {action: "finishPayout", args: {tokenId: args.tokenId}}});
      },
    },
  });
  await t.ctl.pending;
  click(q(t.el, "trigger"));
  await settle(t);
  assert.ok(q(t.el, "finish"));
  // The index saw it paid by someone else: data-rev changes.
  data.status = {...STATUS, due: false, lastRequestAt: NOW, last: {paidAt: NOW, wei: ETH}};
  t.el.dataset.rev = "r2";
  t.ctl.attributesChanged();
  await t.ctl.pending;
  assert.equal(q(t.el, "finish"), null);
  assert.equal(t.el.querySelector("button[data-role=retry]"), null);
  assert.equal(q(t.el, "finished-note").textContent, "This payout has already been finished.");
});

test("data-rev changing reads the status again", async () => {
  const data = {status: STATUS};
  const t = make({read: () => data.status});
  await t.ctl.pending;
  assert.equal(t.state.reads, 1);
  t.ctl.attributesChanged();
  assert.equal(t.state.reads, 1, "nothing changed, nothing is read");
  data.status = {...STATUS, due: false, lastRequestAt: NOW - 10, pending: PENDING};
  t.el.dataset.rev = "r2";
  t.ctl.attributesChanged();
  await t.ctl.pending;
  assert.equal(t.state.reads, 2);
  assert.equal(stateLine(t.el), "A payout is waiting to be finished.");
  assert.ok(q(t.el, "finish"));
});

test("too soon, then the time passes: the timer reads again and Trigger payout appears", async () => {
  const last = NOW - 3600;
  const data = {status: {...STATUS, due: false, lastRequestAt: last}};
  const t = make({read: () => data.status});
  await t.ctl.pending;
  assert.equal(q(t.el, "trigger"), null);
  const timers = liveTimers(t);
  assert.equal(timers.length, 1);
  // Due at last + 1 day, a little after.
  assert.equal(timers[0].ms, (last + 86400 - NOW) * 1000 + 1000);
  t.state.now = last + 86400 + 1;
  data.status = {...STATUS, due: true, lastRequestAt: last};
  timers[0].fn();
  await t.ctl.pending;
  assert.equal(t.state.reads, 2);
  assert.equal(q(t.el, "trigger").textContent, "Trigger payout");
  assert.deepEqual(liveTimers(t).filter(x => x !== timers[0]), [], "nothing more to wait for");
});

test("a next payout far ahead arms the longest timer setTimeout allows, and destroy clears it", async () => {
  const t = make({status: {...STATUS, interval: 31536000, due: false, lastRequestAt: NOW - 10}});
  await t.ctl.pending;
  assert.equal(liveTimers(t)[0].ms, 2 ** 31 - 1);
  t.ctl.destroy();
  assert.equal(liveTimers(t).length, 0);
});

test("only one timer is armed across reads", async () => {
  const t = make({status: {...STATUS, due: false, lastRequestAt: NOW - 3600}});
  await t.ctl.pending;
  await t.ctl.refresh();
  assert.equal(liveTimers(t).length, 1);
});

test("a refresh arriving mid-edit keeps the owner's edits", async () => {
  const t = make({owner: true});
  await t.ctl.pending;
  type(q(t.el, "set-interval"), "3");
  type(q(t.el, "set-fee"), "0.5");
  t.document.dispatchEvent(new t.window.Event("annuart:tx"));
  await t.ctl.pending;
  assert.equal(t.state.reads, 2);
  assert.equal(q(t.el, "set-interval").value, "3");
  assert.equal(q(t.el, "set-fee").value, "0.5");
});

test("an account switch drops unsaved edits, so the form follows the chain again", async () => {
  const t = make({owner: true});
  await t.ctl.pending;
  type(q(t.el, "set-interval"), "3");
  t.setSession({address: "0x" + "ef".repeat(20)});
  await t.ctl.pending;
  t.setSession(SESSION);
  await t.ctl.pending;
  assert.equal(q(t.el, "set-interval").value, "1");
});

test("with a status from the chain the region is marked live; without one it is not", async () => {
  const t = make({session: null});
  await t.ctl.pending;
  assert.equal(t.el.hasAttribute("data-live"), false);
  t.setSession(SESSION);
  await t.ctl.pending;
  assert.equal(t.el.hasAttribute("data-live"), true);
});
