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

function controller(el, {run, finish, session = SESSION, confirm = () => true} = {}) {
  const pushed = [];
  const events = [];
  const failures = [];
  const ctl = new TxActionController(el, {
    push: (name, payload) => pushed.push([name, payload]),
    session: () => session,
    contract: label => (label === "mock" ? CONTRACT : undefined),
    actions: {donate: run, claim: run, transfer: run, unwrap: run, finaliseUnwrap: finish},
    confirm,
    announce: () => events.push("annuart:tx"),
    failed: () => failures.push("annuart:tx-failed"),
  });
  return {ctl, pushed, events, failures};
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
  assert.deepEqual(seen, [["balance", "waiting"], ["authorise", "skipped"], ["encrypt", "active"], ["confirm", "waiting"], ["mined", "waiting"]]);
  const text = [...el.querySelectorAll("ol.steps li")].map(li => li.textContent);
  assert.match(text[0], /^Check your balance: waiting$/);
  assert.match(text[1], /Authorise the contract/);
  assert.match(text[1], /skipped/);
  assert.deepEqual(states(el).map(s => s[1]), ["waiting", "skipped", "done", "done", "done"]);
  assert.match(el.querySelectorAll("ol.steps li")[2].textContent, /Encrypt the amount.*done/);
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
  // With the symbol and decimals the balance check words its message with.
  assert.deepEqual(args, {tokenId: 7n, amount: 150000n, symbol: "TKN", decimals: 2});
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
});

// Once a transaction is out, a retry of the whole action would send it again.
const HASH = "0x" + "ab12".repeat(16);

function minedFails({sentHash = HASH} = {}) {
  let calls = 0;
  const run = async (_s, _c, _a, onStep) => {
    calls += 1;
    onStep("confirm", "active");
    onStep("confirm", "done", {hash: HASH});
    onStep("mined", "active");
    const err = Object.assign(new Error("network down"), sentHash ? {sentHash} : {});
    onStep("mined", "failed", "The transaction failed: network down");
    throw err;
  };
  return {run, calls: () => calls};
}

test("a failure after the transaction was sent offers Start over, not Try again", async () => {
  const {el} = setup({action: "claim"});
  const action = minedFails();
  const {ctl} = controller(el, {run: action.run});
  await ctl.run();
  const failed = el.querySelector("li[data-state=failed]");
  assert.equal(failed.dataset.step, "mined");
  assert.equal(failed.textContent,
    "Done: failed: The transaction failed: network down A transaction was already sent (0xab12ab12…12ab12). Check it before trying again. Start over");
  assert.equal(el.querySelector("button[data-role=retry]"), null);
  assert.equal(failed.querySelector("button[data-role=start-over]").textContent, "Start over");
});

test("Start over asks first, and a declined confirmation reruns nothing", async () => {
  const {el} = setup({action: "claim"});
  const action = minedFails();
  const asked = [];
  let answer = false;
  const {ctl} = controller(el, {run: action.run, confirm: text => { asked.push(text); return answer; }});
  await ctl.run();
  el.querySelector("button[data-role=start-over]").click();
  await ctl.pending;
  assert.deepEqual(asked, ["This sends the transaction again. Continue?"]);
  assert.equal(action.calls(), 1);
  // The run button is no way round it either.
  el.querySelector("button[data-role=run]").click();
  await ctl.pending;
  assert.equal(action.calls(), 1);
  assert.equal(asked.length, 2);

  answer = true;
  el.querySelector("button[data-role=start-over]").click();
  await ctl.pending;
  assert.equal(action.calls(), 2);
});

test("a done sending step is enough to offer Start over, even without a hash on the error", async () => {
  const {el} = setup({action: "claim"});
  const {ctl} = controller(el, {run: minedFails({sentHash: null}).run});
  await ctl.run();
  assert.ok(el.querySelector("button[data-role=start-over]"));
  assert.match(el.querySelector("li[data-state=failed]").textContent, /A transaction was already sent \(0xab12ab12…12ab12\)\./);
});

test("a failure before anything was sent still offers Try again", async () => {
  const {el} = setup({extra: AMOUNT});
  const {ctl} = controller(el, {
    run: async (_s, _c, _a, onStep) => {
      onStep("balance", "active");
      onStep("balance", "failed", "You only have 12 TKN.");
      throw new Error("You only have 12 TKN.");
    },
  });
  await ctl.run();
  assert.equal(el.querySelector("li[data-state=failed]").textContent, "Check your balance: failed: You only have 12 TKN. Try again");
  assert.ok(el.querySelector("button[data-role=retry]"));
  assert.equal(el.querySelector("button[data-role=start-over]"), null);
});

test("an unwrap that fails after its request retries by finishing that request", async () => {
  const requestId = "0x" + "77".repeat(32);
  const {el} = setup({action: "unwrap", extra: AMOUNT});
  let unwraps = 0;
  const finishes = [];
  const {ctl, pushed} = controller(el, {
    run: async (_s, _c, _a, onStep) => {
      unwraps += 1;
      onStep("request", "active");
      onStep("request", "done", {requestId});
      onStep("decrypt", "active");
      onStep("decrypt", "failed", "The unwrap amount could not be decrypted. Try finishing the unwrap again later.");
      throw Object.assign(new Error("could not be decrypted"), {requestId, sentHash: HASH});
    },
    finish: async (_s, c, a, onStep) => {
      finishes.push({c, a});
      onStep("decrypt", "done");
      onStep("finalise", "done");
      onStep("withdraw", "done");
      onStep("mined", "done");
      return {hash: "0xfin"};
    },
  });
  await ctl.run();
  const retry = el.querySelector("button[data-role=retry]");
  assert.equal(retry.textContent, "Try again");
  assert.equal(el.querySelector("button[data-role=start-over]"), null);
  retry.click();
  await ctl.pending;
  assert.equal(unwraps, 1, "the unwrap is not requested again");
  assert.deepEqual(finishes, [{c: CONTRACT, a: {requestId}}]);
  assert.deepEqual(states(el), [["decrypt", "done"], ["finalise", "done"], ["withdraw", "done"], ["mined", "done"]]);
  assert.equal(pushed.length, 1);
  assert.doesNotMatch(JSON.stringify(pushed), /150000|1500/);
});

test("an unwrap whose finishing fails again keeps finishing the same request", async () => {
  const requestId = "0x" + "78".repeat(32);
  const {el} = setup({action: "unwrap", extra: AMOUNT});
  let unwraps = 0;
  const finishes = [];
  const {ctl} = controller(el, {
    run: async () => { unwraps += 1; throw Object.assign(new Error("x"), {requestId, sentHash: HASH}); },
    finish: async (_s, _c, a) => { finishes.push(a); throw new Error("still not decryptable"); },
  });
  await ctl.run();
  el.querySelector("button[data-role=retry]").click();
  await ctl.pending;
  el.querySelector("button[data-role=retry]").click();
  await ctl.pending;
  assert.equal(unwraps, 1);
  assert.deepEqual(finishes, [{requestId}, {requestId}]);
});

test("a failed action is announced as a failure, for the Tokens card to refresh", async () => {
  const {el} = setup({action: "claim"});
  const {ctl, failures, events} = controller(el, {run: async () => { throw new Error("x"); }});
  await ctl.run();
  assert.deepEqual(failures, ["annuart:tx-failed"]);
  assert.deepEqual(events, []);
});

test("a confirmation can name the typed amount, ungrouped, and the recipient", async () => {
  const to = "0x" + "ab".repeat(20);
  const donate = setup({attrs: `data-confirm="Donate {amount} {symbol} to ENFT #7? This cannot be undone."`,
    extra: `<input data-arg="amount" value="123456.5">`});
  const asked = [];
  const d = controller(donate.el, {run: async () => ({hash: "0x1"}), confirm: t => { asked.push(t); return true; }});
  await d.ctl.run();
  const transfer = setup({action: "transfer", attrs: `data-confirm="Transfer ENFT #7 to {to}? Unclaimed balance goes with the ENFT."`,
    extra: `<input data-arg="to" value="${to}">`});
  const t = controller(transfer.el, {run: async () => ({hash: "0x1"}), confirm: x => { asked.push(x); return true; }});
  await t.ctl.run();
  assert.deepEqual(asked, [
    "Donate 123456.5 TKN to ENFT #7? This cannot be undone.",
    `Transfer ENFT #7 to ${to}? Unclaimed balance goes with the ENFT.`,
  ]);
});
