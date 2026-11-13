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
    ? `<select data-role="token">${tokens.map(([l, s, d, k = "standard"], i) => `<option value="${l}"${i === 0 ? " selected" : ""} data-symbol="${s}" data-decimals="${d}" data-nft-kind="${k}">${l} (${s})</option>`).join("")}</select>`
    : `<span data-role="token" data-label="${tokens[0][0]}" data-symbol="${tokens[0][1]}" data-decimals="${tokens[0][2]}" data-nft-kind="${tokens[0][3] ?? "standard"}"></span>`;
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
      <input data-role="name" type="text">
      <span data-role="name-hint"></span>
      <input data-role="donations" type="checkbox" checked>
      <select data-role="recipient-mode"><option value="me" selected>Me</option><option value="other">Another address</option></select>
      <input data-role="recipient" type="text" hidden>
      <div data-role="auto" hidden>
        <input data-role="auto-enabled" type="checkbox" checked>
        <input data-role="auto-interval" type="text" value="1">
        <select data-role="auto-interval-unit"><option value="hours">hours</option><option value="days" selected>days</option><option value="weeks">weeks</option></select>
        <input data-role="auto-fee" type="text" value="0">
        <span data-role="auto-fee-echo"></span>
      </div>
      <p data-role="warning"></p>
      <p data-role="message" role="alert"></p>
      <div data-role="summary" hidden></div>
      <button type="button" data-role="run">Create ENFT</button>
      <ol class="steps"></ol>
    </form></body></html>`);
  return {document, window, el: document.getElementById("create-form")};
}

function make({run, session = SESSION, tokens, now = NOW, confirm = () => true} = {}) {
  const state = {session, now};
  const listeners = [];
  const {el, document} = page({tokens});
  const calls = [];
  const pushed = [];
  const announced = [];
  const asked = [];
  const ctl = new CreateFormController(el, {
    push: (name, payload) => pushed.push([name, payload]),
    session: () => state.session,
    onSession: fn => { listeners.push(fn); return () => {}; },
    contract: label => (label === "mock" ? CONTRACT : label === "auto" ? {...CONTRACT, label: "auto", nftKind: "auto"} : undefined),
    createEnft: run ?? (async (s, c, args, onStep) => { calls.push({s, c, args}); onStep("mined", "done"); return {hash: "0xh", tokenId: 3n}; }),
    announce: () => announced.push(1),
    now: () => state.now,
    confirm: text => { asked.push(text); return confirm(text); },
  });
  const setSession = next => { state.session = next; listeners.forEach(fn => fn(next)); };
  return {ctl, el, document, calls, pushed, announced, asked, state, setSession};
}

const q = (el, role) => el.querySelector(`[data-role=${role}]`);
const type = (input, value) => { input.value = value; input.dispatchEvent(new input.ownerDocument.defaultView.Event("input", {bubbles: true})); };
const pick = (select, value) => {
  // linkedom deselects the other options itself.
  [...select.querySelectorAll("option")].find(o => o.value === value).selected = true; select.dispatchEvent(new select.ownerDocument.defaultView.Event("change", {bubbles: true})); };
const click = node => node.dispatchEvent(new node.ownerDocument.defaultView.Event("click", {bubbles: true}));
const rows = el => [...el.querySelectorAll("[data-role=period]")];

function fillRow(row, {length, unit = "months", rate, per = "day", indefinite = false}) {
  // The last row's box starts ticked, so a fixed length has to untick it.
  const box = q(row, "indefinite");
  if (box && box.checked !== indefinite) {
    box.checked = indefinite;
    box.dispatchEvent(new row.ownerDocument.defaultView.Event("change", {bubbles: true}));
  }
  if (!indefinite) {
    type(q(row, "length"), String(length));
    pick(q(row, "unit"), unit);
  }
  type(q(row, "rate"), String(rate));
  pick(q(row, "per"), per);
}

// 18 months at 100/day, then indefinitely at 25/day.
function fillDefault(el, amount = "1500") {
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
  // The token's symbol and decimals, for the balance check's message.
  assert.equal(args.symbol, "TKN");
  assert.equal(args.decimals, 6);
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
  type(q(t.el, "amount"), "60000");
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
  // A fixed schedule gives a total and a length. The remaining row turns
  // indefinite when it becomes the last, so it is unticked again.
  click(q(second, "remove-period"));
  assert.equal(q(t.el, "total").textContent, "Schedule pays until the endowment runs out.");
  fillRow(first, {length: 18, unit: "months", rate: "100"});
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

test("the last period is indefinite by default, also after adding or removing a period", () => {
  const t = make();
  const last = () => rows(t.el).at(-1);
  assert.equal(q(last(), "indefinite").checked, true);
  assert.equal(q(last(), "length").hidden, true);
  // Unticked, then a period is added: the old row keeps a length, the new last row is indefinite.
  fillRow(last(), {length: 6, rate: "10"});
  click(q(t.el, "add-period"));
  assert.equal(q(rows(t.el)[0], "length").hidden, false);
  assert.equal(q(rows(t.el)[0], "length").value, "6");
  assert.equal(q(last(), "indefinite").checked, true);
  assert.equal(q(last(), "length").hidden, true);
  // Removing the last row makes the remaining one indefinite again; its length is kept for unticking.
  click(q(last(), "remove-period"));
  assert.equal(q(last(), "indefinite").checked, true);
  assert.equal(q(last(), "length").hidden, true);
  assert.equal(q(last(), "length").value, "6");
});

test("a checked Indefinitely replaces the length, and unchecking restores it", () => {
  const t = make();
  const [row] = rows(t.el);
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
  // The lone period is indefinite by default, so only its rate is missing.
  assert.equal(message(t.el), "Period 1: Enter an amount.");
  const box = q(rows(t.el)[0], "indefinite");
  box.checked = false;
  box.dispatchEvent(new t.document.defaultView.Event("change", {bubbles: true}));
  type(q(rows(t.el)[0], "rate"), "1");
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
  type(q(t.el, "amount"), "123456.5");
  assert.equal(t.el.querySelector(".amount-echo").textContent, "= 123456.5 TKN");
  type(q(t.el, "amount"), "1,500");
  assert.equal(t.el.querySelector(".amount-echo").textContent, "Use a period for decimals and no separators, for example 1500.25.");
  type(q(t.el, "amount"), "1.2345678");
  assert.equal(t.el.querySelector(".amount-echo").textContent, "Use at most 6 decimal places.");
  type(q(t.el, "amount"), "");
  assert.equal(t.el.querySelector(".amount-echo").textContent, "");
});

test("a typed name is trimmed, sent with the create and stated in the summary", async () => {
  const t = make();
  fillDefault(t.el);
  type(q(t.el, "name"), "  Rainy day fund ");
  click(q(t.el, "run"));
  const text = q(t.el, "summary").textContent;
  assert.ok(text.includes('It will be named "Rainy day fund". The name is public and cannot be changed later.'), text);
  click(q(t.el, "confirm"));
  await t.ctl.pending;
  assert.equal(t.calls[0].args.name, "Rainy day fund");
});

test("no name is sent as the empty string and the summary says so", async () => {
  const t = make();
  fillDefault(t.el);
  click(q(t.el, "run"));
  assert.ok(q(t.el, "summary").textContent.includes("It will have no name, and one cannot be added later."));
  click(q(t.el, "confirm"));
  await t.ctl.pending;
  assert.equal(t.calls[0].args.name, "");
});

test("a name the contract would refuse is explained as typed and stops the create", async () => {
  for (const [name, problem] of [
    ["<b>bold</b>", "A name can only use letters, digits, spaces and - _ . '"],
    ["café", "A name can only use letters, digits, spaces and - _ . '"],
    ["a".repeat(32), "A name can be at most 31 characters."],
  ]) {
    const t = make();
    fillDefault(t.el);
    type(q(t.el, "name"), name);
    assert.equal(q(t.el, "name-hint").textContent, problem);
    await submit(t);
    assert.equal(message(t.el), problem);
    assert.equal(q(t.el, "summary").hidden, true);
    assert.equal(t.calls.length, 0);
  }
  const t = make();
  fillDefault(t.el);
  type(q(t.el, "name"), "a".repeat(31));
  assert.equal(q(t.el, "name-hint").textContent, "");
  await submit(t);
  assert.equal(t.calls.length, 1);
});

test("a form without a name field still creates, unnamed", async () => {
  const t = make();
  q(t.el, "name").remove();
  q(t.el, "name-hint").remove();
  fillDefault(t.el);
  await submit(t);
  assert.equal(t.calls[0].args.name, "");
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
    "You are about to lock 1500 TKN in a new ENFT.",
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
      // Nothing sent yet (a done authorise would be a transaction already out).
      onStep("balance", "done");
      onStep("authorise", "skipped");
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

test("values the person typed are echoed without grouping; computed totals keep it", async () => {
  const t = make();
  type(q(t.el, "amount"), "60000");
  fillRow(rows(t.el)[0], {length: 18, unit: "months", rate: "1500", per: "month"});
  const [row] = rows(t.el);
  // 1500 a month at 6 decimals is 578 base units a second, so 1498.176 a month.
  assert.equal(q(row, "effective").textContent, "= 1498.176 TKN per month");
  // Computed, not typed: grouped.
  assert.equal(q(row, "upto").textContent, "Up to 26,967.168 TKN");
  assert.equal(q(t.el, "warning").textContent, "33,032.832 TKN extra will be paid to the owner as a lump sum when the schedule ends.");
  click(q(t.el, "run"));
  const text = q(t.el, "summary").textContent;
  assert.ok(text.includes("You are about to lock 60000 TKN in a new ENFT."), text);
  assert.ok(text.includes("18 months at 1498.176 TKN per month"), text);
  assert.ok(text.includes("33032.832 TKN extra"), text);
  assert.doesNotMatch(text, /\d,\d{3}/, "no grouped number in the summary");
});

test("an amount typed with a separator is refused and nothing runs", async () => {
  const t = make();
  for (const bad of ["1,500", "0,500", "1 500", "1'500", "1.500,25"]) {
    fillDefault(t.el, bad);
    await submit(t);
    assert.equal(message(t.el), "Use a period for decimals and no separators, for example 1500.25.", bad);
    for (const row of rows(t.el).slice(1)) click(q(row, "remove-period"));
  }
  assert.equal(t.calls.length, 0);
});

test("the steps start with the balance check", async () => {
  let seen;
  const t = make({run: async (_s, _c, _a, onStep) => {
    seen = [...t.el.querySelectorAll("ol.steps li")].map(li => li.textContent);
    onStep("mined", "done");
    return {hash: "0xh", tokenId: 1n};
  }});
  fillDefault(t.el);
  await submit(t);
  assert.deepEqual(seen, [
    "Check your balance: waiting", "Authorise the contract: waiting", "Encrypt the amount: waiting",
    "Confirm in your wallet: waiting", "Done: waiting",
  ]);
});

test("after the transaction was sent, a failure offers Start over, which asks before showing the summary", async () => {
  const hash = "0x" + "cd34".repeat(16);
  let attempts = 0;
  let answer = false;
  const t = make({
    confirm: () => answer,
    run: async (_s, _c, _a, onStep) => {
      attempts++;
      onStep("balance", "done");
      onStep("authorise", "skipped");
      onStep("encrypt", "done");
      onStep("confirm", "done", {hash});
      onStep("mined", "active");
      if (attempts === 1) throw Object.assign(new Error("lost the receipt"), {sentHash: hash});
      onStep("mined", "done");
      return {hash, tokenId: 4n};
    },
  });
  fillDefault(t.el);
  await submit(t);
  const failed = t.el.querySelector("ol.steps li[data-state=failed]");
  assert.equal(failed.dataset.step, "mined");
  assert.match(failed.textContent, /A transaction was already sent \(0xcd34cd34…34cd34\)\. Check it before trying again\./);
  assert.equal(t.el.querySelector("button[data-role=retry]"), null);
  const startOver = failed.querySelector("button[data-role=start-over]");
  assert.equal(startOver.textContent, "Start over");

  // Declined: nothing, not even a summary.
  click(startOver);
  assert.deepEqual(t.asked, ["This sends the transaction again. Continue?"]);
  assert.equal(q(t.el, "summary").hidden, true);
  // The Create button does not get round it.
  click(q(t.el, "run"));
  assert.equal(t.asked.length, 2);
  assert.equal(q(t.el, "summary").hidden, true);
  assert.equal(attempts, 1);

  // Accepted: the summary again, and only its confirmation sends.
  answer = true;
  click(t.el.querySelector("button[data-role=start-over]"));
  assert.equal(q(t.el, "summary").hidden, false);
  assert.equal(attempts, 1);
  click(q(t.el, "confirm"));
  await t.ctl.pending;
  assert.equal(attempts, 2);
  assert.equal(t.pushed.length, 1);
});

test("the summary warns when payouts start more than ten years from now", () => {
  const t = make();
  fillDefault(t.el);
  pick(q(t.el, "start-mode"), "at");
  type(q(t.el, "start-at"), "2040-01-02T00:00");
  click(q(t.el, "run"));
  assert.ok(q(t.el, "summary").textContent.includes(
    "Payouts do not start until 2 January 2040, more than ten years from now."), q(t.el, "summary").textContent);

  // Within ten years: no such line.
  type(q(t.el, "start-at"), "2039-12-01T00:00");
  click(q(t.el, "run"));
  assert.doesNotMatch(q(t.el, "summary").textContent, /more than ten years/);
});

// Automatic payouts

const AUTO_TOKENS = [["mock", "TKN", 6], ["auto", "TKN", 6, "auto"]];
const autoPage = opts => {
  const t = make({tokens: AUTO_TOKENS, ...opts});
  pick(q(t.el, "token"), "auto");
  return t;
};
const hidden = (el, role) => q(el, role).hasAttribute("hidden");

test("the automatic payout group is hidden for a standard contract and nothing is sent", async () => {
  const t = make({tokens: AUTO_TOKENS});
  assert.equal(hidden(t.el, "auto"), true);
  fillDefault(t.el);
  await submit(t);
  assert.equal(t.calls[0].args.auto, undefined);
});

test("the group shows for an automatic contract (single-token span too) and hides again", () => {
  const single = make({tokens: [["auto", "TKN", 6, "auto"]]});
  assert.equal(hidden(single.el, "auto"), false);
  const t = autoPage();
  assert.equal(hidden(t.el, "auto"), false);
  pick(q(t.el, "token"), "mock");
  assert.equal(hidden(t.el, "auto"), true);
});

test("the defaults give enabled, one day and no fee", async () => {
  const t = autoPage();
  fillDefault(t.el);
  await submit(t);
  assert.deepEqual(t.calls[0].args.auto, {enabled: true, interval: 86400, fee: 0n});
});

test("a typed interval and fee are sent in seconds and wei", async () => {
  const t = autoPage();
  fillDefault(t.el);
  type(q(t.el, "auto-interval"), "36");
  pick(q(t.el, "auto-interval-unit"), "hours");
  type(q(t.el, "auto-fee"), "0.001");
  await submit(t);
  assert.deepEqual(t.calls[0].args.auto, {enabled: true, interval: 129600, fee: 1_000_000_000_000_000n});
});

test("unticking sends enabled: false", async () => {
  const t = autoPage();
  fillDefault(t.el);
  const box = q(t.el, "auto-enabled");
  box.checked = false;
  box.dispatchEvent(new box.ownerDocument.defaultView.Event("change", {bubbles: true}));
  click(q(t.el, "run"));
  assert.match(q(t.el, "summary").textContent, /Automatic payouts are off\./);
  click(q(t.el, "confirm"));
  await t.ctl.pending;
  assert.equal(t.calls[0].args.auto.enabled, false);
});

test("a bad interval stops validation with the interval message", async () => {
  for (const [value, unit] of [["0", "days"], ["400", "days"]]) {
    const t = autoPage();
    fillDefault(t.el);
    type(q(t.el, "auto-interval"), value);
    pick(q(t.el, "auto-interval-unit"), unit);
    click(q(t.el, "run"));
    await t.ctl.pending;
    assert.equal(message(t.el), "The interval must be between 1 hour and 365 days.");
    assert.equal(t.calls.length, 0);
  }
});

test("a fee typed with a separator stops with the amount message", async () => {
  const t = autoPage();
  fillDefault(t.el);
  type(q(t.el, "auto-fee"), "1,5");
  click(q(t.el, "run"));
  await t.ctl.pending;
  assert.match(message(t.el), /separator|decimal|digits|\./i);
  assert.notEqual(message(t.el), "");
  assert.equal(t.calls.length, 0);
});

test("the summary states the interval and the fee", () => {
  const t = autoPage();
  fillDefault(t.el);
  click(q(t.el, "run"));
  assert.match(q(t.el, "summary").textContent, /Automatic payouts are on, at most once every 1 day, with no fee\./);
  type(q(t.el, "auto-fee"), "0.001");
  click(q(t.el, "run"));
  assert.match(q(t.el, "summary").textContent, /Automatic payouts are on, at most once every 1 day, with a fee of up to 0\.001 ETH per payout, never more than 10% of it\./);
});

test("a standard contract's summary says nothing about automatic payouts", () => {
  const t = make();
  fillDefault(t.el);
  click(q(t.el, "run"));
  assert.doesNotMatch(q(t.el, "summary").textContent, /Automatic payouts/);
});

test("a fee above 10% of one interval's payout is called out", () => {
  const t = autoPage();
  fillDefault(t.el);
  // About 100 TKN per day: one day's payout is just under 0.1 ETH, so 10% is just under 0.01.
  type(q(t.el, "auto-fee"), "0.009");
  assert.equal(q(t.el, "auto-fee-echo").textContent.includes("capped"), false);
  type(q(t.el, "auto-fee"), "0.011");
  assert.match(q(t.el, "auto-fee-echo").textContent, /The fee is capped at 10% of each payout\./);
});
