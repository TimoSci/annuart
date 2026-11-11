// The button-plus-step-list every chain action uses. The logic lives in
// TxActionController, which takes its collaborators as arguments so it can be
// tested without LiveView; TxAction is the thin LiveView hook around it.
//
// Amounts are read from [data-arg] inputs, parsed here and handed to the
// action. They never leave the browser: the one event pushed to the server,
// "tx:confirmed", carries {action, label, tokenId, hash} and nothing else.
import {parseAmount, formatAmount} from "../units.js";
import {explain, explainAmount} from "../errors.js";
import {current, chainInfo} from "../chain/signer.js";
import * as actions from "../chain/actions.js";

const LABELS = {
  balance: "Check your balance",
  authorise: "Authorise the contract",
  encrypt: "Encrypt the amount",
  confirm: "Confirm in your wallet",
  mined: "Done",
  deposit: "Convert ETH to WETH",
  approve: "Approve WETH",
  wrap: "Wrap",
  request: "Request unwrap",
  decrypt: "Wait for decryption",
  finalise: "Finalise unwrap",
  withdraw: "Convert WETH to ETH",
};

const SEND = ["confirm", "mined"];
const WITH_ENCRYPT = ["balance", "authorise", "encrypt", "confirm", "mined"];
const FINISH = ["decrypt", "finalise", "withdraw", "mined"];
// The steps each action reports, in order, so they can all show "waiting".
const PLANS = {
  createEnft: WITH_ENCRYPT,
  donate: WITH_ENCRYPT,
  wrap: ["deposit", "approve", "wrap", "mined"],
  unwrap: ["balance", "encrypt", "request", ...FINISH],
  finaliseUnwrap: FINISH,
};
// Steps that are done once their transaction has been broadcast.
const SENDING = new Set(["authorise", "confirm", "deposit", "approve", "wrap", "request", "finalise", "withdraw"]);

// A transaction pending this long may have been dropped by the wallet.
export const STILL_WAITING_MS = 180_000;
export const STILL_WAITING_NOTE =
  "Still waiting. If your wallet shows this transaction as dropped, reload the page and check your balance before trying again.";

export const START_OVER_QUESTION = "This sends the transaction again. Continue?";
const shortHash = hash => (hash.length > 18 ? `${hash.slice(0, 10)}…${hash.slice(-6)}` : hash);

const STATE_TEXT = {waiting: "waiting", active: "in progress", done: "done", skipped: "skipped"};
const ADDRESS = /^0x[0-9a-fA-F]{40}$/;
const ETH_DECIMALS = 18;
// A value the person typed is shown back without digit grouping.
const TYPED = {grouping: false};

class InputError extends Error {}

// The step list an action reports into: one <li> per step, and a failure with
// its reason and a way to go on. Shared by every form that runs an action.
//
// Before any transaction went out, the way on is "Try again" (data-role
// "retry"). After one did, rerunning the whole action would send it again, so
// the failure says so and offers "Start over" (data-role "start-over"), which
// the form must confirm with START_OVER_QUESTION before it reruns anything.
export class StepList {
  // opts.setTimeout / opts.clearTimeout time the "still waiting" note.
  constructor(list, opts = {}) {
    this.setTimer = opts.setTimeout ?? ((fn, ms) => globalThis.setTimeout(fn, ms));
    this.clearTimer = opts.clearTimeout ?? (t => globalThis.clearTimeout(t));
    this.timer = null;
    this.list = list;
    this.doc = list.ownerDocument;
    this.steps = [];
    this.recovery = null;
  }

  // Shows every step the action will report, all waiting.
  begin(action) {
    this.steps = (PLANS[action] ?? SEND).map(id => ({id, state: "waiting"}));
    this.recovery = null;
    this.stopWaiting();
    this.render();
  }

  report(id, state, detail) {
    let step = this.steps.find(s => s.id === id);
    if (!step) { step = {id, state}; this.steps.push(step); }
    step.state = state;
    step.detail = detail;
    this.stopWaiting();
    this.render();
  }

  // The action broadcast step `id`'s transaction: from now on that step waits
  // on the network, and gets a note if that takes too long. Never armed during
  // the wallet prompt, which is before the broadcast.
  sent(id) {
    const step = this.steps.find(s => s.id === id);
    if (!step || step.state !== "active") return;
    this.stopWaiting();
    this.timer = this.setTimer(() => {
      this.timer = null;
      if (step.state === "active") { step.waitingNote = true; this.render(); }
    }, STILL_WAITING_MS);
  }

  // Clears the timer and every "still waiting" note.
  stopWaiting() {
    if (this.timer !== null) this.clearTimer(this.timer);
    this.timer = null;
    for (const step of this.steps) step.waitingNote = false;
  }

  // An action that threw without reporting leaves its step active, or no step
  // failed at all: the failure goes on the first step not yet finished.
  // Returns how the failure may be recovered from: {kind: "retry"} or
  // {kind: "start-over", hash}.
  fail(err) {
    this.stopWaiting();
    const active = this.steps.filter(step => step.state === "active");
    if (active.length === 0 && !this.steps.some(step => step.state === "failed")) {
      const next = this.steps.find(step => step.state === "waiting");
      if (next) active.push(next);
    }
    for (const step of active) { step.state = "failed"; step.detail = explain(err); }
    return this.offer(this.recoveryFor(err));
  }

  // Shows `recovery` as the way on from the failure, and returns it.
  offer(recovery) {
    this.recovery = recovery;
    this.render();
    return recovery;
  }

  // A transaction was broadcast if the action says so (err.sentHash) or a
  // step that sends one was reported done.
  recoveryFor(err) {
    const sent = this.steps.filter(step => SENDING.has(step.id) && step.state === "done");
    const hash = err?.replacement?.hash ?? err?.sentHash ?? sent.map(step => step.detail?.hash).filter(Boolean).at(-1) ?? null;
    return hash || sent.length > 0 ? {kind: "start-over", hash} : {kind: "retry"};
  }

  render() {
    const items = this.steps.map(step => {
      const li = this.doc.createElement("li");
      li.dataset.step = step.id;
      li.dataset.state = step.state;
      const name = LABELS[step.id] ?? step.id;
      if (step.state === "failed") {
        const startOver = this.recovery?.kind === "start-over";
        let text = `${name}: failed: ${step.detail ?? ""} `;
        if (startOver) {
          const hash = this.recovery.hash ? ` (${shortHash(this.recovery.hash)})` : "";
          text += `A transaction was already sent${hash}. Check it before trying again. `;
        }
        li.append(text);
        const button = this.doc.createElement("button");
        button.type = "button";
        button.dataset.role = startOver ? "start-over" : "retry";
        button.textContent = startOver ? "Start over" : "Try again";
        li.append(button);
      } else {
        li.append(`${name}: ${STATE_TEXT[step.state]}`);
        if (step.waitingNote) li.append(` ${STILL_WAITING_NOTE}`);
      }
      return li;
    });
    this.list.replaceChildren(...items);
  }
}

export class TxActionController {
  constructor(el, deps) {
    this.el = el;
    this.deps = deps;
    this.doc = el.ownerDocument;
    this.running = false;
    this.pending = null;
    // After a failure: {kind: "retry"} reruns at the next click, {kind:
    // "start-over"} only once confirmed. `finishing` is the request id of an
    // unwrap that failed after its request was mined: the next run finishes it.
    this.recovery = null;
    this.finishing = null;

    this.message = this.doc.createElement("p");
    this.message.className = "tx-message";
    this.message.setAttribute("role", "alert");
    this.list = el.querySelector("ol.steps");
    this.list.before(this.message);
    this.stepList = new StepList(this.list, {setTimeout: deps.setTimeout, clearTimeout: deps.clearTimeout});

    this.echoes = [...el.querySelectorAll("[data-arg=amount], [data-arg=wei]")].map(input => {
      const echo = this.doc.createElement("span");
      echo.className = "amount-echo";
      input.after(echo);
      return {input, echo};
    });
    this.onInput = event => {
      const found = this.echoes.find(e => e.input === event.target);
      if (found) this.updateEcho(found);
    };
    this.onClick = event => {
      const button = event.target.closest?.("button[data-role]");
      if (button && el.contains(button) && !button.disabled) this.run();
    };
    el.addEventListener("input", this.onInput);
    el.addEventListener("click", this.onClick);
    this.echoes.forEach(e => this.updateEcho(e));
  }

  destroy() {
    this.stepList.stopWaiting();
    this.el.removeEventListener("input", this.onInput);
    this.el.removeEventListener("click", this.onClick);
  }

  get symbol() { return this.el.dataset.symbol ?? ""; }

  // [decimals, symbol] for an amount input, or throws when they are unknown.
  unitsFor(input) {
    if (input.dataset.arg === "wei") return [ETH_DECIMALS, "ETH"];
    const decimals = this.el.dataset.decimals;
    if (decimals === undefined || decimals === "") throw new InputError("Token details are unavailable. Try again later.");
    return [Number(decimals), this.symbol];
  }

  parse(input) {
    const [decimals, symbol] = this.unitsFor(input);
    try {
      return {value: parseAmount(input.value, decimals), decimals, symbol};
    } catch (err) {
      throw new InputError(explainAmount(err, symbol));
    }
  }

  updateEcho({input, echo}) {
    if (input.value.trim() === "") { echo.textContent = ""; return; }
    try {
      const {value, decimals, symbol} = this.parse(input);
      echo.textContent = `= ${formatAmount(value, decimals, TYPED)} ${symbol}`.trim();
    } catch (err) {
      echo.textContent = err.message;
    }
  }

  // Reads and validates every [data-arg] input, plus the token id.
  // An amount comes with its symbol and decimals, for the balance check's message.
  readArgs() {
    const args = {};
    if (this.el.dataset.tokenId) args.tokenId = BigInt(this.el.dataset.tokenId);
    for (const input of this.el.querySelectorAll("[data-arg]")) {
      const name = input.dataset.arg;
      if (name === "wei") args.wei = this.parse(input).value;
      else if (name === "amount") {
        const {value, symbol, decimals} = this.parse(input);
        Object.assign(args, {amount: value, symbol, decimals});
      } else if (name === "to") {
        const to = input.value.trim();
        if (!ADDRESS.test(to)) throw new InputError("Enter a valid address, starting with 0x.");
        args.to = to;
      } else args[name] = input.value.trim();
    }
    return args;
  }

  say(text) { this.message.textContent = text; }

  // Every click (the action's button or the failed step's) goes through what
  // the last failure left, so nothing reruns a sent transaction unasked.
  run() {
    if (this.running) return this.pending;
    if (this.recovery?.kind === "start-over" && !this.deps.confirm(START_OVER_QUESTION)) return this.pending;
    this.pending = this.finishing
      ? this.execute("finaliseUnwrap", {requestId: this.finishing})
      : this.attempt();
    return this.pending;
  }

  async attempt() {
    if (this.running) return;
    const {action, question} = {...this.el.dataset};
    this.say("");
    let args;
    try {
      args = this.readArgs();
    } catch (err) {
      if (!(err instanceof InputError)) throw err;
      this.say(err.message);
      return;
    }
    if (!this.deps.session()) { this.say("Connect a wallet first."); return; }
    if (!this.deps.actions[action] || !this.deps.contract(this.el.dataset.label)) { this.say("This action is not available."); return; }
    if (question && !this.deps.confirm(this.confirmText(question, args))) return;
    return this.execute(action, args);
  }

  // The confirmation, with {amount} (as typed, ungrouped), {symbol} and {to}
  // filled in from the inputs. It is shown in the browser only.
  confirmText(template, args) {
    const fill = {
      amount: args.amount !== undefined ? formatAmount(args.amount, args.decimals, TYPED) : "",
      symbol: this.symbol,
      to: args.to ?? "",
    };
    return template.replace(/\{(amount|symbol|to)\}/g, (_, key) => fill[key]);
  }

  // Runs `action`; on failure, remembers how to go on.
  async execute(action, args) {
    const {label} = this.el.dataset;
    const session = this.deps.session();
    const run = this.deps.actions[action];
    const contract = this.deps.contract(label);
    if (!session) { this.say("Connect a wallet first."); return; }
    if (!run || !contract) { this.say("This action is not available."); return; }
    this.running = true;
    this.setBusy(true);
    this.stepList.begin(action);
    try {
      const report = (id, state, detail) => this.stepList.report(id, state, detail);
      report.sent = (id, hash) => this.stepList.sent(id, hash);
      const result = await run(session, contract, args, report);
      this.recovery = null;
      this.finishing = null;
      this.deps.push("tx:confirmed", {action, label, tokenId: this.el.dataset.tokenId ?? null, hash: result?.hash ?? null});
      this.deps.announce();
    } catch (err) {
      this.recovery = this.stepList.fail(err);
      // An unwrap whose request is on chain is finished from then on, never
      // requested again: finishing sends nothing the request already did.
      if (action === "unwrap" && err?.requestId) {
        this.finishing = err.requestId;
        this.recovery = this.stepList.offer({kind: "retry"});
      }
      this.deps.failed?.();
    } finally {
      this.running = false;
      this.setBusy(false);
    }
  }

  setBusy(busy) {
    const button = this.el.querySelector("button[data-role=run]");
    if (button) button.disabled = busy;
  }
}

export const TxAction = {
  mounted() {
    this.controller = new TxActionController(this.el, {
      push: (name, payload) => this.pushEvent(name, payload),
      session: current,
      contract: label => chainInfo().contracts.find(c => c.label === label),
      actions,
      confirm: text => window.confirm(text),
      announce: () => window.dispatchEvent(new CustomEvent("annuart:tx")),
      failed: () => window.dispatchEvent(new CustomEvent("annuart:tx-failed")),
    });
  },
  destroyed() {
    this.controller?.destroy();
  },
};
