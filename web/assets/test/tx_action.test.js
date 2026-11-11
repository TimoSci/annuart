import test from "node:test";
import assert from "node:assert/strict";
import {parseHTML} from "linkedom";
import {TxActionController} from "../js/hooks/tx_action.js";
import {SecretController} from "../js/hooks/secret_value.js";

const CONTRACT = {label: "mock", nft: "0xnft", token: "0xtok", tokenKind: "mock"};
const SESSION = {address: "0xabc"};

function setup({action = "donate", extra = "", attrs = ""} = {}) {
  const {document, window} = parseHTML(`<html><body>
    <div id="tx" data-action="${action}" data-label="mock" data-token-id="7" data-decimals="2" data-symbol="TKN" ${attrs}>
      ${extra}
      <button type="button" data-role="run">Go</button>
      <ol class="steps"></ol>
    </div></body></html>`);
  return {document, window, el: document.getElementById("tx")};
}

function controller(el, {run, session = SESSION, confirm = () => true} = {}) {
  const pushed = [];
  const events = [];
  const ctl = new TxActionController(el, {
    push: (name, payload) => pushed.push([name, payload]),
    session: () => session,
    contract: label => (label === "mock" ? CONTRACT : undefined),
    actions: {donate: run, claim: run, transfer: run},
    confirm,
    announce: () => events.push("annuart:tx"),
  });
  return {ctl, pushed, events};
}

const states = el => [...el.querySelectorAll("ol.steps li")].map(li => [li.dataset.step, li.dataset.state]);
const AMOUNT = `<input data-arg="amount" value="1500">`;

test("renders steps as the action reports them", async () => {
  const {el} = setup({extra: AMOUNT});
  let seen;
  const {ctl} = controller(el, {
    run: async (_s, _c, _a, onStep) => {
      onStep("authorise", "skipped");
      onStep("encrypt", "active");
      seen = states(el);
      onStep("encrypt", "done");
      onStep("confirm", "active");
      onStep("confirm", "done");
      onStep("mined", "done");
      return {hash: "0xh"};
    },
  });
  assert.deepEqual(states(el).length, 0);
  await ctl.run();
  assert.deepEqual(seen, [["authorise", "skipped"], ["encrypt", "active"], ["confirm", "waiting"], ["mined", "waiting"]]);
  const text = [...el.querySelectorAll("ol.steps li")].map(li => li.textContent);
  assert.match(text[0], /Authorise the contract/);
  assert.match(text[0], /skipped/);
  assert.deepEqual(states(el).map(s => s[1]), ["skipped", "done", "done", "done"]);
  assert.match(el.querySelectorAll("ol.steps li")[1].textContent, /Encrypt the amount.*done/);
});

test("shows in progress for the active step", async () => {
  const {el} = setup({extra: AMOUNT});
  let during;
  const {ctl} = controller(el, {
    run: async (_s, _c, _a, onStep) => {
      onStep("encrypt", "active");
      during = el.querySelector("ol.steps li[data-state=active]").textContent;
      return {hash: "0xh"};
    },
  });
  await ctl.run();
  assert.match(during, /Encrypt the amount.*in progress/);
});

test("a failed step shows the explained message and a retry", async () => {
  const {el} = setup({extra: AMOUNT});
  const {ctl, pushed} = controller(el, {
    run: async (_s, _c, _a, onStep) => {
      onStep("confirm", "active");
      onStep("confirm", "failed", "The transaction failed: boom");
      throw new Error("boom");
    },
  });
  await ctl.run();
  const failed = el.querySelector("li[data-state=failed]");
  assert.match(failed.textContent, /failed: The transaction failed: boom/);
  assert.ok(el.querySelector("button[data-role=retry]"));
  assert.match(el.querySelector("button[data-role=retry]").textContent, /Try again/);
  assert.deepEqual(pushed, []);
});

test("retry runs the action again from the start", async () => {
  const {el} = setup({action: "claim"});
  let calls = 0;
  const {ctl, pushed} = controller(el, {
    run: async (_s, _c, _a, onStep) => {
      calls += 1;
      onStep("confirm", "active");
      if (calls === 1) {
        onStep("confirm", "failed", "nope");
        throw new Error("x");
      }
      onStep("confirm", "done");
      onStep("mined", "done");
      return {hash: "0xh2"};
    },
  });
  await ctl.run();
  el.querySelector("button[data-role=retry]").click();
  await ctl.pending;
  assert.equal(calls, 2);
  assert.equal(el.querySelector("button[data-role=retry]"), null);
  assert.deepEqual(states(el).map(s => s[1]), ["done", "done"]);
  assert.equal(pushed.length, 1);
});

test("user rejection leaves no step in progress", async () => {
  const {el} = setup({extra: AMOUNT});
  const {ctl} = controller(el, {
    run: async (_s, _c, _a, onStep) => {
      onStep("encrypt", "active");
      onStep("encrypt", "done");
      onStep("confirm", "active");
      // an action that throws without reporting the failure
      const err = new Error("rejected");
      err.code = 4001;
      throw err;
    },
  });
  await ctl.run();
  assert.equal(el.querySelectorAll("li[data-state=active]").length, 0);
  assert.match(el.querySelector("li[data-state=failed]").textContent, /You cancelled the request in your wallet\./);
  assert.equal(el.querySelector("button[data-role=run]").disabled, false);
});

test("an invalid amount is refused before any action runs", async () => {
  const {el} = setup({extra: `<input data-arg="amount" value="1,500">`});
  let ran = false;
  const {ctl, pushed} = controller(el, {run: async () => { ran = true; }});
  await ctl.run();
  assert.equal(ran, false);
  assert.equal(pushed.length, 0);
  assert.equal(el.querySelector(".tx-message").textContent, "Use a period for decimals and no separators, for example 1500.25.");
  assert.equal(states(el).length, 0);
});

test("the pushed event contains no amount", async () => {
  const {el} = setup({extra: AMOUNT});
  const {ctl, pushed, events} = controller(el, {run: async () => ({hash: "0xfeed", tokenId: 9n, amount: 150000n})});
  await ctl.run();
  assert.deepEqual(pushed, [["tx:confirmed", {action: "donate", label: "mock", tokenId: "7", hash: "0xfeed"}]]);
  assert.doesNotMatch(JSON.stringify(pushed), /1500|150000/);
  assert.deepEqual(events, ["annuart:tx"]);
});

test("amount inputs are parsed and passed with the token id, by name", async () => {
  const {el} = setup({extra: AMOUNT});
  let args;
  const {ctl} = controller(el, {run: async (_s, _c, a) => { args = a; return {hash: "0x1"}; }});
  await ctl.run();
  assert.deepEqual(args, {tokenId: 7n, amount: 150000n});
});

test("a to input is passed through as text and an invalid address is refused", async () => {
  const good = "0x" + "ab".repeat(20);
  const {el} = setup({action: "transfer", extra: `<input data-arg="to" value="${good}">`});
  let args;
  const {ctl} = controller(el, {run: async (_s, _c, a) => { args = a; return {hash: "0x1"}; }});
  await ctl.run();
  assert.deepEqual(args, {tokenId: 7n, to: good});

  const bad = setup({action: "transfer", extra: `<input data-arg="to" value="nonsense">`});
  let ran = false;
  const c2 = controller(bad.el, {run: async () => { ran = true; }});
  await c2.ctl.run();
  assert.equal(ran, false);
  assert.match(bad.el.querySelector(".tx-message").textContent, /address/);
});

test("without a wallet nothing runs and the person is told to connect", async () => {
  const {el} = setup({extra: AMOUNT});
  let ran = false;
  const {ctl} = controller(el, {session: null, run: async () => { ran = true; }});
  await ctl.run();
  assert.equal(ran, false);
  assert.match(el.querySelector(".tx-message").textContent, /Connect a wallet first\./);
});

test("a declined confirmation runs nothing", async () => {
  const {el} = setup({action: "transfer", attrs: `data-confirm="Sure?"`, extra: `<input data-arg="to" value="0x${"ab".repeat(20)}">`});
  let ran = false;
  let asked;
  const {ctl} = controller(el, {run: async () => { ran = true; }, confirm: t => { asked = t; return false; }});
  await ctl.run();
  assert.equal(asked, "Sure?");
  assert.equal(ran, false);
});

test("the amount echo shows the parsed value, or the reason it is invalid", () => {
  const {el, document, window} = setup({extra: `<input data-arg="amount" value="">`});
  controller(el, {run: async () => ({})});
  const input = el.querySelector("[data-arg=amount]");
  const echo = () => el.querySelector(".amount-echo").textContent;
  // What was typed is shown back without digit grouping.
  input.value = "1500.25";
  input.dispatchEvent(new window.Event("input", {bubbles: true}));
  assert.equal(echo(), "= 1500.25 TKN");
  input.value = "1,500";
  input.dispatchEvent(new window.Event("input", {bubbles: true}));
  assert.equal(echo(), "Use a period for decimals and no separators, for example 1500.25.");
  input.value = "abc";
  input.dispatchEvent(new window.Event("input", {bubbles: true}));
  assert.equal(echo(), "Enter the amount as a number.");
  input.value = "";
  input.dispatchEvent(new window.Event("input", {bubbles: true}));
  assert.equal(echo(), "");
  assert.ok(document);
});

test("the controller works for an action with no inputs", async () => {
  const {el} = setup({action: "claim"});
  let args;
  const {ctl, pushed} = controller(el, {run: async (_s, _c, a) => { args = a; return {hash: "0x2"}; }});
  await ctl.run();
  assert.deepEqual(args, {tokenId: 7n});
  assert.equal(pushed[0][1].hash, "0x2");
});

// SecretValue

function secret(kind = "distribution", {session = SESSION, reveal} = {}) {
  const {document, window} = parseHTML(
    `<html><body><span id="s" data-secret="${kind}" data-label="mock" data-id="3" data-decimals="2" data-symbol="TKN"></span></body></html>`);
  const el = document.getElementById("s");
  const calls = [];
  const ctl = new SecretController(el, {
    session: () => session,
    contract: () => CONTRACT,
    reveal: {
      distribution: async (...a) => { calls.push(["distribution", ...a]); return reveal ?? 123456n; },
      balance: async (...a) => { calls.push(["balance", ...a]); return reveal ?? 123456n; },
    },
    target: window,
  });
  return {el, ctl, calls, window};
}

test("a secret starts hidden and reveals on click, then hides again", async () => {
  const {el, ctl, calls} = secret();
  assert.match(el.textContent, /•••••/);
  el.querySelector("button").click();
  await ctl.pending;
  assert.match(el.textContent, /1,234\.56 TKN/);
  assert.equal(el.querySelector("button").textContent, "Hide");
  assert.deepEqual(calls, [["distribution", SESSION, CONTRACT, 3n]]);
  el.querySelector("button").click();
  assert.match(el.textContent, /•••••/);
  assert.equal(el.querySelector("button").textContent, "Reveal");
});

test("a balance secret reads the balance", async () => {
  const {el, ctl, calls} = secret("balance");
  el.querySelector("button").click();
  await ctl.pending;
  assert.deepEqual(calls, [["balance", SESSION, CONTRACT]]);
});

test("annuart:tx resets a revealed secret to hidden", async () => {
  const {el, ctl, window} = secret();
  el.querySelector("button").click();
  await ctl.pending;
  window.dispatchEvent(new window.Event("annuart:tx"));
  assert.match(el.textContent, /•••••/);
  assert.doesNotMatch(el.textContent, /TKN/);
  ctl.destroy();
});

test("revealing without a wallet says so", async () => {
  const {el, ctl} = secret("distribution", {session: null});
  el.querySelector("button").click();
  await ctl.pending;
  assert.match(el.textContent, /Connect a wallet first\./);
  assert.match(el.textContent, /•••••/);
});

test("an action that throws before reporting any step fails on the first step, with a retry", async () => {
  const {el} = setup({action: "claim"});
  let calls = 0;
  const {ctl} = controller(el, {
    run: async () => {
      calls += 1;
      if (calls === 1) throw new Error("Only a wrapped token can be wrapped.");
      return {hash: "0x1"};
    },
  });
  await ctl.run();
  const items = [...el.querySelectorAll("ol.steps li")];
  assert.deepEqual(states(el), [["confirm", "failed"], ["mined", "waiting"]]);
  assert.match(items[0].textContent, /failed: The transaction failed: Only a wrapped token can be wrapped\./);
  el.querySelector("button[data-role=retry]").click();
  await ctl.pending;
  assert.equal(calls, 2);
  assert.equal(el.querySelector("button[data-role=retry]"), null);
});

test("a throw after step one is done fails the next step and leaves step one done", async () => {
  const {el} = setup({action: "claim"});
  const {ctl} = controller(el, {
    run: async (_s, _c, _a, onStep) => {
      onStep("confirm", "active");
      onStep("confirm", "done");
      throw new Error("boom");
    },
  });
  await ctl.run();
  assert.deepEqual(states(el), [["confirm", "done"], ["mined", "failed"]]);
  assert.match(el.querySelector("li[data-state=failed]").textContent, /failed: The transaction failed: boom/);
  assert.ok(el.querySelector("button[data-role=retry]"));
});
