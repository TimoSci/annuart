import test from "node:test";
import assert from "node:assert/strict";
import {parseHTML} from "linkedom";
import {CreateFormController} from "../js/hooks/create_form.js";
import {U64_MAX} from "../js/units.js";

// Dates are shown in the browser's own time zone, as the date input is.
process.env.TZ = "UTC";

const ME = "0x" + "ab".repeat(20);
const OTHER = "0x" + "cd".repeat(20);
const SESSION = {address: ME};
const DAY = 86400;
// Mid-2030, in milliseconds.
const NOW = Date.UTC(2030, 0, 1);
const CONTRACT = {label: "mock", nft: "0xnft", token: "0xtok", tokenKind: "mock"};

// The static markup CreateLive renders; the hook fills in the rows.
function page({tokens = [["mock", "TKN", 6]]} = {}) {
  const token = tokens.length > 1
    ? `<select data-role="token">${tokens.map(([l, s, d], i) => `<option value="${l}"${i === 0 ? " selected" : ""} data-symbol="${s}" data-decimals="${d}">${l} (${s})</option>`).join("")}</select>`
    : `<span data-role="token" data-label="${tokens[0][0]}" data-symbol="${tokens[0][1]}" data-decimals="${tokens[0][2]}"></span>`;
  const {document, window} = parseHTML(`<html><body>
    <form id="create-form">
      ${token}
      <input data-role="amount" type="text">
      <span data-role="balance" data-secret="balance"></span>
      <div data-role="periods"></div>
      <button type="button" data-role="add-period">+ Add period</button>
      <div data-role="chart"></div>
      <p data-role="total"></p>
      <select data-role="start-mode"><option value="now" selected>Now</option><option value="at">On</option></select>
      <input data-role="start-at" type="datetime-local" hidden>
      <input data-role="donations" type="checkbox" checked>
      <select data-role="recipient-mode"><option value="me" selected>Me</option><option value="other">Another address</option></select>
      <input data-role="recipient" type="text" hidden>
      <p data-role="warning"></p>
      <p data-role="message" role="alert"></p>
      <div data-role="summary" hidden></div>
      <button type="button" data-role="run">Create ENFT</button>
      <ol class="steps"></ol>
    </form></body></html>`);
  return {document, window, el: document.getElementById("create-form")};
}

function make({run, session = SESSION, tokens, now = NOW} = {}) {
  const state = {session, now};
  const listeners = [];
  const {el, document} = page({tokens});
  const calls = [];
  const pushed = [];
  const announced = [];
  const ctl = new CreateFormController(el, {
    push: (name, payload) => pushed.push([name, payload]),
    session: () => state.session,
    onSession: fn => { listeners.push(fn); return () => {}; },
    contract: label => (label === "mock" ? CONTRACT : undefined),
    createEnft: run ?? (async (s, c, args, onStep) => { calls.push({s, c, args}); onStep("mined", "done"); return {hash: "0xh", tokenId: 3n}; }),
    announce: () => announced.push(1),
    now: () => state.now,
  });
  const setSession = next => { state.session = next; listeners.forEach(fn => fn(next)); };
  return {ctl, el, document, calls, pushed, announced, state, setSession};
}

const q = (el, role) => el.querySelector(`[data-role=${role}]`);
const type = (input, value) => { input.value = value; input.dispatchEvent(new input.ownerDocument.defaultView.Event("input", {bubbles: true})); };
const pick = (select, value) => {
  // linkedom deselects the other options itself.
  [...select.querySelectorAll("option")].find(o => o.value === value).selected = true; select.dispatchEvent(new select.ownerDocument.defaultView.Event("change", {bubbles: true})); };
const click = node => node.dispatchEvent(new node.ownerDocument.defaultView.Event("click", {bubbles: true}));
const rows = el => [...el.querySelectorAll("[data-role=period]")];

function fillRow(row, {length, unit = "months", rate, per = "day", indefinite = false}) {
  if (indefinite) {
    const box = q(row, "indefinite");
    box.checked = true;
    box.dispatchEvent(new row.ownerDocument.defaultView.Event("change", {bubbles: true}));
  } else {
    type(q(row, "length"), String(length));
    pick(q(row, "unit"), unit);
  }
  type(q(row, "rate"), String(rate));
  pick(q(row, "per"), per);
}

// 18 months at 100/day, then indefinitely at 25/day.
function fillDefault(el, amount = "1,500") {
  type(q(el, "amount"), amount);
  click(q(el, "add-period"));
  const [first, second] = rows(el);
  fillRow(first, {length: 18, unit: "months", rate: "100"});
  fillRow(second, {indefinite: true, rate: "25"});
}

// Create, then confirm in the summary.
async function submit(t) {
  click(q(t.el, "run"));
  const confirm = q(t.el, "confirm");
  if (confirm) click(confirm);
  await t.ctl.pending;
}

const message = el => q(el, "message").textContent;

test("collects rows into segments and calls createEnft with them", async () => {
  const t = make();
  fillDefault(t.el);
  await submit(t);
  assert.equal(t.calls.length, 1);
  const {args, c} = t.calls[0];
  assert.equal(c, CONTRACT);
  assert.equal(args.amount, 1_500_000_000n);
  assert.equal(args.to, ME);
  assert.equal(args.start, 0n);
  assert.equal(args.topUps, true);
  // 6 decimals: 100 and 25 tokens a day, rounded down to whole units a second.
  assert.deepEqual(args.segments, [
    {duration: 18n * 30n * 86400n, ratePerSec: 100_000_000n / 86400n},
    {duration: U64_MAX, ratePerSec: 25_000_000n / 86400n},
  ]);
  assert.deepEqual(t.pushed, [["tx:confirmed", {action: "createEnft", label: "mock", tokenId: "3", hash: "0xh"}]]);
  assert.equal(t.announced.length, 1);
});

test("shows the stops_early warning with a date", () => {
  const t = make();
  type(q(t.el, "amount"), "1000");
  fillRow(rows(t.el)[0], {length: 18, unit: "months", rate: "100"});
  // 100/day wants about 54,000 over 540 days; 1,000 lasts about 10 days from 2030-01-01.
  assert.match(q(t.el, "warning").textContent, /Your endowment is less than the schedule total\. Payouts will stop early, around 11 January 2030\./);
});

test("shows the leftover warning with the extra amount and symbol", () => {
  const t = make();
  type(q(t.el, "amount"), "60,000");
  fillRow(rows(t.el)[0], {length: 18, unit: "months", rate: "100"});
  assert.match(q(t.el, "warning").textContent, /^6,019.008 TKN extra will be paid to the owner as a lump sum when the schedule ends\.$/);
});

test("shows the runs_dry warning for an indefinite schedule", () => {
  const t = make();
  type(q(t.el, "amount"), "1000");
  fillRow(rows(t.el)[0], {indefinite: true, rate: "100"});
  assert.match(q(t.el, "warning").textContent, /^At these rates the endowment runs out around 11 January 2030\.$/);
});

test("shows the total line, per-row effective rate and up-to, and the chart", () => {
  const t = make();
  fillDefault(t.el);
  const [first, second] = rows(t.el);
  assert.match(q(first, "effective").textContent, /99.9648 TKN per day/);
  assert.match(q(first, "upto").textContent, /Up to 53,980.992 TKN/);
  assert.match(q(second, "upto").textContent, /until the endowment runs out/i);
  assert.equal(q(t.el, "total").textContent, "Schedule pays until the endowment runs out.");
  assert.equal(t.el.querySelectorAll("[data-role=chart] [data-role=bar]").length, 2);
  // A fixed schedule gives a total and a length.
  click(q(second, "remove-period"));
  assert.equal(q(t.el, "total").textContent, "Schedule pays up to 53,980.992 TKN in total over 18 months.");
});

test("a rate is shown after rounding, and a rate that rounds to zero says so", () => {
  const t = make();
  const [row] = rows(t.el);
  fillRow(row, {length: 1, unit: "days", rate: "1", per: "year"}); // 1 token a year is 1,000,000 units over 31,536,000 s: under one a second
  assert.match(q(row, "effective").textContent, /too small to pay anything/);
});

test("refuses a rate that rounds to zero with the specific message", async () => {
  const t = make();
  type(q(t.el, "amount"), "1000");
  fillRow(rows(t.el)[0], {length: 1, unit: "days", rate: "0.01", per: "year"});
  await submit(t);
  assert.match(message(t.el), /This rate is too small to pay anything\. Enter a larger rate\./);
  assert.equal(t.calls.length, 0);
});

test("refuses an amount with too many decimals", async () => {
  const t = make();
  fillDefault(t.el, "1.2345678");
  await submit(t);
  assert.equal(message(t.el), "Use at most 6 decimal places.");
  assert.equal(q(t.el, "summary").hidden, true);
  assert.equal(t.calls.length, 0);
});

test("refuses an amount above uint64", async () => {
  const t = make();
  fillDefault(t.el, "999999999999999999999");
  await submit(t);
  assert.equal(message(t.el), "That is more TKN than a single ENFT can hold.");
  assert.equal(t.calls.length, 0);
});

test("refuses an invalid recipient address", async () => {
  const t = make();
  fillDefault(t.el);
  pick(q(t.el, "recipient-mode"), "other");
  for (const bad of ["", "0x123", "0x" + "0".repeat(40), "0x" + "zz".repeat(20), "0xAb5801a7D398351b8bE11C439e05C5B3259aeC9b"]) {
    type(q(t.el, "recipient"), bad);
    await submit(t);
    assert.match(message(t.el), /valid address/, bad);
  }
  assert.equal(t.calls.length, 0);
  // A lowercase address is accepted, and goes to the contract.
  type(q(t.el, "recipient"), OTHER);
  await submit(t);
  assert.equal(t.calls[0].args.to, OTHER);
});

test("refuses a start date in the past", async () => {
  const t = make();
  fillDefault(t.el);
  pick(q(t.el, "start-mode"), "at");
  type(q(t.el, "start-at"), "2029-12-31T10:00");
  await submit(t);
  assert.match(message(t.el), /start.*future/i);
  assert.equal(t.calls.length, 0);
  type(q(t.el, "start-at"), "");
  await submit(t);
  assert.match(message(t.el), /Choose a start/);
});

test("a chosen start is passed as unix seconds", async () => {
  const t = make();
  fillDefault(t.el);
  pick(q(t.el, "start-mode"), "at");
  type(q(t.el, "start-at"), "2031-06-01T12:00");
  await submit(t);
  assert.equal(t.calls[0].args.start, BigInt(Math.floor(new Date("2031-06-01T12:00").getTime() / 1000)));
});

test("the start plus the fixed durations must stay below 2^64 - 1", async () => {
  const t = make();
  type(q(t.el, "amount"), "1000");
  // The durations alone are below the bound; adding 2030 as a start is not.
  const years = U64_MAX / 31536000n;
  assert.ok(U64_MAX - years * 31536000n < BigInt(NOW / 1000));
  fillRow(rows(t.el)[0], {length: years.toString(), unit: "years", rate: "1"});
  await submit(t);
  assert.equal(message(t.el), "This schedule runs too far into the future.");
  assert.equal(t.calls.length, 0);
});

test("the Indefinitely checkbox is offered only on the last row", () => {
  const t = make();
  assert.equal(t.el.querySelectorAll("[data-role=indefinite]").length, 1);
  click(q(t.el, "add-period"));
  click(q(t.el, "add-period"));
  const boxes = rows(t.el).map(r => q(r, "indefinite"));
  assert.deepEqual(boxes.map(b => b !== null), [false, false, true]);
  // Removing the last row moves the checkbox to the new last row.
  click(q(rows(t.el)[2], "remove-period"));
  assert.deepEqual(rows(t.el).map(r => q(r, "indefinite") !== null), [false, true]);
});

test("a checked Indefinitely replaces the length, and unchecking restores it", () => {
  const t = make();
  const [row] = rows(t.el);
  q(row, "indefinite").checked = true;
  q(row, "indefinite").dispatchEvent(new t.document.defaultView.Event("change", {bubbles: true}));
  assert.equal(q(row, "length").hidden, true);
  assert.equal(q(row, "unit").hidden, true);
  q(row, "indefinite").checked = false;
  q(row, "indefinite").dispatchEvent(new t.document.defaultView.Event("change", {bubbles: true}));
  assert.equal(q(row, "length").hidden, false);
});

test("the last remaining period cannot be removed", () => {
  const t = make();
  assert.equal(q(rows(t.el)[0], "remove-period"), null);
});

test("without a wallet nothing is validated further and the person is told to connect", async () => {
  const t = make({session: null});
  fillDefault(t.el, "nonsense");
  await submit(t);
  assert.equal(message(t.el), "Connect a wallet first.");
  assert.equal(t.calls.length, 0);
});

test("validation stops at the first failure, in order: amount, rows, recipient, start", async () => {
  const t = make();
  // Everything is wrong; the amount is reported first.
  pick(q(t.el, "recipient-mode"), "other");
  type(q(t.el, "recipient"), "nope");
  pick(q(t.el, "start-mode"), "at");
  await submit(t);
  assert.equal(message(t.el), "Enter an amount.");
  type(q(t.el, "amount"), "1000");
  await submit(t);
  assert.match(message(t.el), /^Period 1: Every period needs a length\.$/);
  fillRow(rows(t.el)[0], {length: 1, unit: "months", rate: "1"});
  await submit(t);
  assert.match(message(t.el), /valid address/);
  type(q(t.el, "recipient"), OTHER);
  await submit(t);
  assert.match(message(t.el), /Choose a start/);
});

test("the amount echo shows the parsed value, or the reason it is invalid", () => {
  const t = make();
  type(q(t.el, "amount"), "1500");
  assert.equal(t.el.querySelector(".amount-echo").textContent, "= 1,500 TKN");
  type(q(t.el, "amount"), "1.2345678");
  assert.equal(t.el.querySelector(".amount-echo").textContent, "Use at most 6 decimal places.");
  type(q(t.el, "amount"), "");
  assert.equal(t.el.querySelector(".amount-echo").textContent, "");
});

test("a summary precedes the first transaction and states what will be locked", async () => {
  const t = make();
  fillDefault(t.el);
  pick(q(t.el, "recipient-mode"), "other");
  type(q(t.el, "recipient"), OTHER);
  pick(q(t.el, "start-mode"), "at");
  type(q(t.el, "start-at"), "2031-06-01T12:00");
  click(q(t.el, "run"));
  const summary = q(t.el, "summary");
  assert.equal(summary.hidden, false);
  assert.equal(t.calls.length, 0, "nothing runs before confirmation");
  const text = summary.textContent;
  for (const part of [
    "1,500 TKN",
    OTHER,
    "1 June 2031, 12:00",
    "Donations are allowed",
    "cannot be changed",
    "18 months at 99.9648 TKN per day",
    "then indefinitely at 24.9696 TKN per day",
    "At these rates the endowment runs out around 16 June 2031",
  ]) assert.ok(text.includes(part), `summary mentions ${part}: ${text}`);
  assert.equal(t.pushed.length, 0);
});

test("the summary for the default options says now, me and no donations when off", () => {
  const t = make();
  fillDefault(t.el);
  q(t.el, "donations").checked = false;
  click(q(t.el, "run"));
  const text = q(t.el, "summary").textContent;
  assert.match(text, /start as soon as the transaction is mined/);
  assert.ok(text.includes(`${ME} (you)`));
  assert.match(text, /Donations are not allowed/);
});

test("cancelling the summary sends nothing and runs nothing", async () => {
  const t = make();
  fillDefault(t.el);
  click(q(t.el, "run"));
  click(q(t.el, "cancel"));
  await t.ctl.pending;
  assert.equal(q(t.el, "summary").hidden, true);
  assert.equal(t.calls.length, 0);
  assert.equal(t.pushed.length, 0);
  assert.equal(t.announced.length, 0);
  assert.equal(t.el.querySelectorAll("ol.steps li").length, 0);
});

test("a failed step shows a retry; retrying shows the summary again and then runs", async () => {
  let attempts = 0;
  const t = make({
    run: async (_s, _c, _a, onStep) => {
      attempts++;
      onStep("authorise", "done");
      onStep("encrypt", "active");
      if (attempts === 1) throw Object.assign(new Error("x"), {code: 4001});
      onStep("mined", "done");
      return {hash: "0xh", tokenId: 9n};
    },
  });
  fillDefault(t.el);
  await submit(t);
  const failed = t.el.querySelector("ol.steps li[data-state=failed]");
  assert.match(failed.textContent, /Encrypt the amount: failed: You cancelled the request in your wallet\./);
  assert.equal(t.pushed.length, 0);
  click(failed.querySelector("button[data-role=retry]"));
  assert.equal(q(t.el, "summary").hidden, false);
  assert.equal(attempts, 1);
  click(q(t.el, "confirm"));
  await t.ctl.pending;
  assert.equal(attempts, 2);
  assert.deepEqual(t.pushed[0][1].tokenId, "9");
});

test("the event pushed on success carries only action, label, tokenId and hash", async () => {
  const t = make();
  fillDefault(t.el, "123456");
  await submit(t);
  assert.deepEqual(Object.keys(t.pushed[0][1]).sort(), ["action", "hash", "label", "tokenId"]);
  assert.ok(!JSON.stringify(t.pushed).includes("123456"));
});

test("with several tokens the selection decides decimals, symbol and contract", async () => {
  const t = make({tokens: [["mock", "TKN", 6], ["other", "WTK", 2]]});
  pick(q(t.el, "token"), "mock");
  type(q(t.el, "amount"), "1.5");
  assert.equal(t.el.querySelector(".amount-echo").textContent, "= 1.5 TKN");
  t.announced.length = 0;
  pick(q(t.el, "token"), "other");
  assert.equal(t.el.querySelector(".amount-echo").textContent, "= 1.5 WTK");
  assert.equal(q(t.el, "balance").dataset.label, "other");
  assert.equal(q(t.el, "balance").dataset.decimals, "2");
  assert.equal(t.announced.length, 1, "a revealed balance of the old token is hidden");
});

test("after success the form stays locked and a second attempt runs nothing", async () => {
  const t = make();
  fillDefault(t.el);
  await submit(t);
  assert.equal(t.calls.length, 1);
  assert.match(message(t.el), /^Created\./);
  for (const node of t.el.querySelectorAll("input, select, button")) {
    assert.ok(node.hasAttribute("disabled") || node.disabled, `${node.dataset.role} is disabled`);
  }
  click(q(t.el, "run"));
  assert.equal(q(t.el, "confirm"), null);
  t.ctl.run();
  await t.ctl.pending;
  assert.equal(q(t.el, "confirm"), null);
  assert.equal(q(t.el, "summary").hidden, true);
  assert.equal(t.calls.length, 1);
  assert.equal(t.pushed.length, 1);
});

test("a failed create does not lock the form", async () => {
  const t = make({run: async () => { throw new Error("boom"); }});
  fillDefault(t.el);
  await submit(t);
  assert.equal(t.el.querySelector("[data-role=run]").hasAttribute("disabled"), false);
  assert.equal(q(t.el, "amount").hasAttribute("disabled"), false);
});

test("a wallet change discards a pending summary", async () => {
  const t = make();
  fillDefault(t.el);
  click(q(t.el, "run"));
  assert.equal(q(t.el, "summary").hidden, false);
  t.setSession({address: OTHER});
  assert.equal(q(t.el, "summary").hidden, true);
  assert.equal(q(t.el, "confirm"), null);
  assert.equal(t.calls.length, 0);
});

test("confirming re-checks that a chosen start is still in the future", async () => {
  const t = make();
  fillDefault(t.el);
  pick(q(t.el, "start-mode"), "at");
  type(q(t.el, "start-at"), "2030-01-01T10:00");
  click(q(t.el, "run"));
  assert.equal(q(t.el, "summary").hidden, false);
  // Minutes pass; the start is now behind us.
  t.state.now = Date.UTC(2030, 0, 1, 10, 5);
  click(q(t.el, "confirm"));
  await t.ctl.pending;
  assert.match(message(t.el), /start.*future/i);
  assert.equal(q(t.el, "summary").hidden, true);
  assert.equal(t.calls.length, 0);
});
