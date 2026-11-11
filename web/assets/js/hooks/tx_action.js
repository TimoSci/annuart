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
const WITH_ENCRYPT = ["authorise", "encrypt", "confirm", "mined"];
const FINISH = ["decrypt", "finalise", "withdraw", "mined"];
// The steps each action reports, in order, so they can all show "waiting".
const PLANS = {
  createEnft: WITH_ENCRYPT,
  donate: WITH_ENCRYPT,
  wrap: ["deposit", "approve", "wrap", "mined"],
  unwrap: ["encrypt", "request", ...FINISH],
  finaliseUnwrap: FINISH,
};

const STATE_TEXT = {waiting: "waiting", active: "in progress", done: "done", skipped: "skipped"};
const ADDRESS = /^0x[0-9a-fA-F]{40}$/;
const ETH_DECIMALS = 18;
// A value the person typed is shown back without digit grouping.
const TYPED = {grouping: false};

class InputError extends Error {}

// The step list an action reports into: one <li> per step, a failure with its
// reason and a "Try again" button. Shared by every form that runs an action.
export class StepList {
  constructor(list) {
    this.list = list;
    this.doc = list.ownerDocument;
    this.steps = [];
  }

  // Shows every step the action will report, all waiting.
  begin(action) {
    this.steps = (PLANS[action] ?? SEND).map(id => ({id, state: "waiting"}));
    this.render();
  }

  report(id, state, detail) {
    let step = this.steps.find(s => s.id === id);
    if (!step) { step = {id, state}; this.steps.push(step); }
    step.state = state;
    step.detail = detail;
    this.render();
  }

  // An action that threw without reporting leaves its step active, or no step
  // failed at all: the failure goes on the first step not yet finished.
  fail(err) {
    const active = this.steps.filter(step => step.state === "active");
    if (active.length === 0 && !this.steps.some(step => step.state === "failed")) {
      const next = this.steps.find(step => step.state === "waiting");
      if (next) active.push(next);
    }
    for (const step of active) { step.state = "failed"; step.detail = explain(err); }
    this.render();
  }

  render() {
    const items = this.steps.map(step => {
      const li = this.doc.createElement("li");
      li.dataset.step = step.id;
      li.dataset.state = step.state;
      const name = LABELS[step.id] ?? step.id;
      if (step.state === "failed") {
        li.append(`${name}: failed: ${step.detail ?? ""} `);
        const retry = this.doc.createElement("button");
        retry.type = "button";
        retry.dataset.role = "retry";
        retry.textContent = "Try again";
        li.append(retry);
      } else {
        li.append(`${name}: ${STATE_TEXT[step.state]}`);
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

    this.message = this.doc.createElement("p");
    this.message.className = "tx-message";
    this.message.setAttribute("role", "alert");
    this.list = el.querySelector("ol.steps");
    this.list.before(this.message);
    this.stepList = new StepList(this.list);

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
  readArgs() {
    const args = {};
    if (this.el.dataset.tokenId) args.tokenId = BigInt(this.el.dataset.tokenId);
    for (const input of this.el.querySelectorAll("[data-arg]")) {
      const name = input.dataset.arg;
      if (name === "amount" || name === "wei") args[name] = this.parse(input).value;
      else if (name === "to") {
        const to = input.value.trim();
        if (!ADDRESS.test(to)) throw new InputError("Enter a valid address, starting with 0x.");
        args.to = to;
      } else args[name] = input.value.trim();
    }
    return args;
  }

  say(text) { this.message.textContent = text; }

  run() {
    this.pending = this.attempt();
    return this.pending;
  }

  async attempt() {
    if (this.running) return;
    const {action, label, confirm} = {...this.el.dataset};
    this.say("");
    let args;
    try {
      args = this.readArgs();
    } catch (err) {
      if (!(err instanceof InputError)) throw err;
      this.say(err.message);
      return;
    }
    const session = this.deps.session();
    if (!session) { this.say("Connect a wallet first."); return; }
    const run = this.deps.actions[action];
    const contract = this.deps.contract(label);
    if (!run || !contract) { this.say("This action is not available."); return; }
    if (confirm && !this.deps.confirm(confirm)) return;

    this.running = true;
    this.setBusy(true);
    this.stepList.begin(action);
    try {
      const result = await run(session, contract, args, (id, state, detail) => this.stepList.report(id, state, detail));
      this.deps.push("tx:confirmed", {action, label, tokenId: this.el.dataset.tokenId ?? null, hash: result?.hash ?? null});
      this.deps.announce();
    } catch (err) {
      this.stepList.fail(err);
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
    });
  },
  destroyed() {
    this.controller?.destroy();
  },
};
