// The ENFT page's automatic payout controls. EnftLive renders the public,
// indexed settings around this region; this reads what only the chain knows
// right now (whether a payout is due or pending) and draws Trigger payout or
// Finish payout, and for the owner the settings form. Logic lives in
// AutoPayoutController, which takes its collaborators as arguments so it can
// be tested without LiveView; AutoPayout is the thin LiveView hook.
//
// Nothing typed here leaves the browser except through the action itself: the
// inputs carry data-role and no name, and the one event pushed to the server
// is TxActionController's "tx:confirmed" with {action, label, tokenId, hash}.
// Everything drawn from chain data is set as text, never as HTML.
import {formatAmount, intervalSeconds, parseFee, INTERVAL_UNITS} from "../units.js";
import {explainAmount} from "../errors.js";
import {current, onChange, chainInfo, WrongChainError} from "../chain/signer.js";
import * as actions from "../chain/actions.js";
import {TxActionController} from "./tx_action.js";

const ETH_DECIMALS = 18;
// A value shown back in an input or a note, without digit grouping.
const TYPED = {grouping: false};
const DEFAULT_INTERVAL = 86400;

export const SWITCH_ON_QUESTION = "Switch automatic payouts on? Each payout amount becomes public.";
// The Create form's wording, word for word.
const PRIVACY_NOTE = "Anyone can trigger these payouts, and you receive them as plain ETH. Each automatic payout amount is public. If the ENFT ever runs out, that reveals how much it held in total.";
const FEE_NOTE = "At most 10% of each payout is ever paid as a fee.";
const NO_WALLET = "Connect a wallet to trigger a payout.";
const UNAVAILABLE = "Automatic payout status is unavailable.";
const WRONG_CHAIN = "Switch your wallet to the right network to see this.";
const ALREADY_FINISHED = "This payout has already been finished.";
// setTimeout runs at most this far ahead; a later next-payout time re-arms.
const MAX_TIMER_MS = 2 ** 31 - 1;
// Read again a moment after the next payout becomes possible, not before.
const TIMER_MARGIN_MS = 1000;
// The browser's clock may run ahead of the chain's block time, which decides
// whether a payout is due: past the next-possible time, read again this often,
// for this long, before waiting for something else to prompt a read.
const RETRY_MS = 15_000;
const RETRY_FOR_SECONDS = 600;

// The button each payout action is offered under.
const BUTTONS = {
  triggerPayout: {role: "trigger", text: "Trigger payout"},
  finishPayout: {role: "finish", text: "Finish payout"},
};

const setHidden = (node, hidden) => {
  if (hidden) node.setAttribute("hidden", ""); else node.removeAttribute("hidden");
};

function dateTimeText(seconds) {
  return new Date(seconds * 1000).toLocaleString("en-GB", {
    day: "numeric", month: "long", year: "numeric", hour: "2-digit", minute: "2-digit",
  });
}

// An interval in seconds as the form's number and unit: the largest unit that
// divides it evenly ("1" "days" for 86400, "36" "hours" for 129600). One set
// some other way that no unit divides leaves the number blank, for the owner
// to enter, rather than prefilling a value that is not the chain's.
function intervalFields(seconds) {
  const s = seconds > 0 ? seconds : DEFAULT_INTERVAL;
  const units = Object.entries(INTERVAL_UNITS).sort(([, a], [, b]) => b - a);
  const found = units.find(([, per]) => s % per === 0);
  return found ? {value: String(s / found[1]), unit: found[0]} : {value: "", unit: "hours"};
}

// A TxActionController whose button carries its own data-role (trigger,
// finish, save) instead of "run".
class RoleAction extends TxActionController {
  setBusy(busy) {
    const button = this.el.querySelector("button.tx-run");
    if (button) button.disabled = busy;
  }

  // Whether anything is on screen from a run: steps, a failure, a note.
  get used() { return this.stepList.steps.length > 0 || this.message.textContent !== ""; }

  // What the next click runs: the finishing action a failure left, or its own.
  get effective() { return this.finishing?.action ?? this.el.dataset.action; }

  // A trigger sends the fee it showed as minFee, so the request fails if the
  // owner has lowered it since.
  readArgs() {
    const args = super.readArgs();
    if (this.minFee !== undefined) args.minFee = this.minFee;
    return args;
  }
}

// Save: its arguments come from the settings form, validated and, when
// switching payouts on, confirmed by `prepare` before anything is sent.
class SaveAction extends RoleAction {
  constructor(el, deps, prepare) {
    super(el, deps);
    this.prepare = prepare;
  }

  async attempt() {
    this.say("");
    const prepared = this.prepare();
    if (prepared.error) { this.say(prepared.error); return; }
    if (!this.deps.session()) { this.say("Connect a wallet first."); return; }
    if (prepared.question && !this.deps.confirm(prepared.question)) return;
    return this.execute("setAutoPayout", prepared.args);
  }
}

export class AutoPayoutController {
  constructor(el, deps) {
    this.el = el;
    this.deps = deps;
    this.doc = el.ownerDocument;
    this.generation = 0;
    this.pending = null;
    // The last read: {kind: "ok", status} | {kind: "no-wallet"} | {kind: "failed", wrongChain}.
    this.result = null;
    // Kept across reads, so a failure (and what finishes it) stays on screen.
    this.payout = null;
    this.settings = null;
    // The owner has edited the form since it was last filled from the chain.
    this.dirty = false;
    this.owner = el.dataset.owner === "true";
    // The server's digest of the indexed settings and payouts: when it changes,
    // someone changed the chain, so the status is read again.
    this.rev = el.dataset.rev;
    this.timer = null;
    this.schedule = deps.schedule ?? ((fn, ms) => globalThis.setTimeout(fn, ms));
    this.cancel = deps.cancel ?? (t => globalThis.clearTimeout(t));

    this.stateLine = this.text("p", "", "auto-state");
    this.stateLine.dataset.role = "state";
    this.triggerNote = this.text("p", "", "note");
    this.triggerNote.dataset.role = "trigger-note";
    this.slot = this.doc.createElement("div");
    this.slot.dataset.role = "payout";
    this.finishedNote = this.text("p", ALREADY_FINISHED, "note");
    this.finishedNote.dataset.role = "finished-note";
    el.replaceChildren(this.stateLine, this.slot);

    // A failed action may still have changed the chain (a request that was
    // mined), so a failure re-reads the status too.
    this.onTx = () => this.refresh();
    deps.target.addEventListener("annuart:tx", this.onTx);
    deps.target.addEventListener("annuart:tx-failed", this.onTx);
    // Another account's edits are not the owner's: the form is filled afresh.
    this.unsubscribe = deps.onSession?.(() => { this.dirty = false; this.refresh(); });
    this.refresh();
  }

  destroy() {
    this.deps.target.removeEventListener("annuart:tx", this.onTx);
    this.deps.target.removeEventListener("annuart:tx-failed", this.onTx);
    if (typeof this.unsubscribe === "function") this.unsubscribe();
    // A read still in flight is stale: it renders nothing and arms no timer.
    this.destroyed = true;
    this.generation += 1;
    this.stopTimer();
    this.payout?.destroy();
    this.settings?.action.destroy();
  }

  // The promises of the actions drawn by this controller, for tests to await.
  get pendingActions() {
    return [this.payout, this.settings?.action].map(c => c?.pending).filter(Boolean);
  }

  get tokenId() { return this.el.dataset.tokenId; }

  text(tag, text, className) {
    const node = this.doc.createElement(tag);
    node.textContent = text;
    if (className) node.className = className;
    return node;
  }

  refresh() {
    this.pending = this.load();
    return this.pending;
  }

  // A background read: it never asks the wallet anything.
  async load() {
    const generation = ++this.generation;
    const session = this.deps.session();
    const contract = this.deps.contract(this.el.dataset.label);
    let result;
    if (!session) result = {kind: "no-wallet"};
    else if (!contract) result = {kind: "failed", wrongChain: false};
    else {
      try {
        result = {kind: "ok", status: await this.deps.actions.autoPayoutStatus(session, contract, BigInt(this.tokenId))};
      } catch (err) {
        result = {kind: "failed", wrongChain: err instanceof WrongChainError};
      }
    }
    // A newer read has started (or the controller is gone): that one decides.
    if (generation !== this.generation || this.destroyed) return;
    this.result = result;
    this.render();
  }

  // LiveView changed this region's data attributes. data-owner (the wallet
  // connected or switched) shows or hides the form; data-rev (the index saw a
  // new setting or payout) means the chain changed, so the status is read again.
  attributesChanged() {
    const owner = this.el.dataset.owner === "true";
    const rev = this.el.dataset.rev;
    if (rev !== this.rev) {
      this.rev = rev;
      this.owner = owner;
      this.refresh();
    } else if (owner !== this.owner) {
      this.owner = owner;
      this.render();
    }
  }

  stopTimer() {
    if (this.timer !== null) this.cancel(this.timer);
    this.timer = null;
  }

  // Too soon for a payout: read again once the next one is possible, and, while
  // the chain has not caught up with that time, every RETRY_MS for a while.
  armTimer(status) {
    this.stopTimer();
    if (!status || status.pending || !status.enabled || status.due || status.lastRequestAt === null) return;
    if (this.destroyed) return;
    const late = this.deps.now() - (status.lastRequestAt + status.interval);
    let ms;
    if (late < 0) ms = Math.min(-late * 1000 + TIMER_MARGIN_MS, MAX_TIMER_MS);
    else if (late <= RETRY_FOR_SECONDS) ms = RETRY_MS;
    else return;
    this.timer = this.schedule(() => { this.timer = null; this.refresh(); }, ms);
  }

  render() {
    if (!this.result) return;
    const status = this.result.kind === "ok" ? this.result.status : null;
    // With a status read from the chain, this region's line replaces the
    // server's line from the index (see app.css).
    if (status) this.el.dataset.live = ""; else delete this.el.dataset.live;
    this.stateLine.textContent = this.stateText(this.result);
    this.armTimer(status);
    this.renderPayout(status);
    this.renderSettings(status);
  }

  stateText(result) {
    if (result.kind === "no-wallet") return NO_WALLET;
    if (result.kind === "failed") return result.wrongChain ? WRONG_CHAIN : UNAVAILABLE;
    const s = result.status;
    if (s.pending) return "A payout is waiting to be finished.";
    if (!s.enabled) return "";
    if (s.due) return "A payout can be triggered now.";
    if (s.lastRequestAt !== null) {
      const next = s.lastRequestAt + s.interval;
      if (next > this.deps.now()) return `Next payout possible ${dateTimeText(next)}.`;
    }
    return "";
  }

  txDeps(overrides = {}) {
    const d = this.deps;
    return {
      session: d.session, contract: d.contract, actions: d.actions, push: d.push,
      confirm: d.confirm, announce: d.announce, failed: d.failed,
      setTimeout: d.setTimeout, clearTimeout: d.clearTimeout, ...overrides,
    };
  }

  // A <div class="tx"> in the markup TxActionController expects.
  txBlock(action, button) {
    const wrap = this.doc.createElement("div");
    wrap.className = "tx";
    wrap.dataset.action = action;
    wrap.dataset.label = this.el.dataset.label;
    wrap.dataset.tokenId = this.tokenId;
    const steps = this.doc.createElement("ol");
    steps.className = "steps";
    wrap.append(button, steps);
    return wrap;
  }

  button(role, text) {
    const button = this.doc.createElement("button");
    button.type = "button";
    button.className = "tx-run";
    button.dataset.role = role;
    button.textContent = text;
    return button;
  }

  dropPayout() {
    this.payout.destroy();
    this.payout.el.remove();
    this.payout = null;
  }

  // Trigger payout when one is due, Finish payout when one is pending, read
  // from the chain just now. The action drawn is kept while it runs, and kept
  // when a failure left it finishing what the chain now shows pending: a
  // trigger whose request was mined is finished from then on, never requested
  // again. One that has shown its outcome stays, without its button.
  renderPayout(status) {
    setHidden(this.slot, !status);
    if (!status) return;
    const wanted = status.pending ? "finishPayout" : status.enabled && status.due ? "triggerPayout" : null;
    let c = this.payout;
    let finished = false;
    // Nothing due or pending: a failure left on screen has nothing to retry (a
    // payout someone else finished), so it goes, with a line saying so.
    if (c && !c.running && !wanted && c.recovery) {
      finished = c.effective === "finishPayout";
      this.dropPayout();
      c = null;
    }
    if (c && !c.running && (wanted ? c.effective !== wanted : !c.used)) { this.dropPayout(); c = null; }
    if (!c && wanted) {
      const {role, text} = BUTTONS[wanted];
      const button = this.button(role, text);
      c = this.payout = new RoleAction(this.txBlock(wanted, button), this.txDeps());
      c.button = button;
    }
    if (!c) { this.slot.replaceChildren(...(finished ? [this.finishedNote] : [])); return; }
    const shown = c.running ? c.effective : wanted;
    if (shown) {
      c.button.dataset.role = BUTTONS[shown].role;
      c.button.textContent = BUTTONS[shown].text;
      if (c.button.parentNode !== c.el) c.el.prepend(c.button);
    } else c.button.remove();
    const items = [];
    if (shown === "triggerPayout") {
      let note = "You pay the transaction fees.";
      if (status.fee > 0n) note += ` You receive up to ${formatAmount(status.fee, ETH_DECIMALS, TYPED)} ETH as the fee.`;
      this.triggerNote.textContent = note;
      c.minFee = status.fee;
      items.push(this.triggerNote);
    }
    this.slot.replaceChildren(...items, c.el);
  }

  renderSettings(status) {
    if (!this.owner || !status) {
      if (this.settings) setHidden(this.settings.root, true);
      return;
    }
    if (!this.settings) this.settings = this.buildSettings();
    setHidden(this.settings.root, false);
    if (!this.dirty && !this.settings.action.running) this.prefill(status);
  }

  role(root, name) { return root.querySelector(`[data-role=${name}]`); }

  field(label, ...nodes) {
    const row = this.doc.createElement("div");
    row.className = "field";
    row.append(label, ...nodes);
    return row;
  }

  label(text, input) {
    const label = this.text("label", text);
    input.id = `${this.el.id || "auto-payout"}-${input.dataset.role}`;
    label.setAttribute("for", input.id);
    return label;
  }

  input(role, {type = "text", inputmode} = {}) {
    const input = this.doc.createElement("input");
    input.type = type;
    input.dataset.role = role;
    input.setAttribute("autocomplete", "off");
    if (inputmode) input.setAttribute("inputmode", inputmode);
    return input;
  }

  buildSettings() {
    const root = this.doc.createElement("div");
    root.className = "auto-settings";
    root.dataset.role = "settings";

    const enabled = this.input("set-enabled", {type: "checkbox"});
    const interval = this.input("set-interval", {inputmode: "numeric"});
    const unit = this.doc.createElement("select");
    unit.dataset.role = "set-interval-unit";
    for (const name of Object.keys(INTERVAL_UNITS)) {
      const option = this.text("option", name);
      option.value = name;
      unit.append(option);
    }
    const fee = this.input("set-fee", {inputmode: "decimal"});
    const echo = this.text("span", "", "amount-echo");
    echo.dataset.role = "set-fee-echo";
    const intervalNote = this.text("span", "", "amount-echo");
    intervalNote.dataset.role = "interval-note";

    const save = this.button("save", "Save");
    const block = this.txBlock("setAutoPayout", save);
    root.append(
      this.text("h3", "Your settings"),
      this.field(this.label("Automatic payouts", enabled), enabled),
      this.text("p", PRIVACY_NOTE, "note"),
      this.field(this.label("At most once every", interval), interval, unit, intervalNote),
      this.field(this.label("Fee per payout (ETH)", fee), fee, echo),
      this.text("p", FEE_NOTE, "note"),
      block,
    );
    this.el.append(root);

    const edited = event => {
      if (!root.contains(event.target) || block.contains(event.target)) return;
      this.dirty = true;
      if (event.target === fee) this.echoFee(fee, echo);
    };
    root.addEventListener("input", edited);
    root.addEventListener("change", edited);

    // A saved form is filled from the chain again when the status is re-read.
    const action = new SaveAction(block, this.txDeps({
      announce: () => { this.dirty = false; this.deps.announce(); },
    }), () => this.prepare());
    return {root, action, enabled, interval, unit, intervalNote, fee, echo};
  }

  echoFee(input, echo) {
    try {
      const wei = parseFee(input.value);
      echo.textContent = wei === 0n ? "" : `= ${formatAmount(wei, ETH_DECIMALS, TYPED)} ETH`;
    } catch (err) {
      echo.textContent = explainAmount(err, "ETH");
    }
  }

  prefill(status) {
    const f = this.settings;
    f.enabled.checked = Boolean(status.enabled);
    const {value, unit} = intervalFields(status.interval);
    f.interval.value = value;
    // A blank box says why: the chain's interval is no whole number of hours.
    f.intervalNote.textContent = value === "" ? `The interval is ${status.interval} seconds.` : "";
    // Selecting one option of a single select deselects the others.
    const option = [...f.unit.querySelectorAll("option")].find(o => o.value === unit);
    if (option) option.selected = true;
    f.fee.value = formatAmount(status.fee ?? 0n, ETH_DECIMALS, TYPED);
    this.echoFee(f.fee, f.echo);
  }

  // The settings to send, or why they cannot be. The contract checks the
  // interval whether payouts are on or off, so it is always checked here.
  prepare() {
    const f = this.settings;
    let interval, fee;
    try {
      interval = intervalSeconds(f.interval.value, f.unit.value);
    } catch (err) {
      return {error: explainAmount(err, "ETH")};
    }
    try {
      fee = parseFee(f.fee.value);
    } catch (err) {
      return {error: explainAmount(err, "ETH")};
    }
    const enabled = Boolean(f.enabled.checked);
    const wasOn = this.result?.kind === "ok" && this.result.status.enabled;
    return {
      args: {tokenId: BigInt(this.tokenId), enabled, interval, fee},
      question: enabled && !wasOn ? SWITCH_ON_QUESTION : null,
    };
  }
}

export const AutoPayout = {
  mounted() {
    const contract = label => chainInfo().contracts.find(c => c.label === label);
    this.controller = new AutoPayoutController(this.el, {
      session: current,
      onSession: onChange,
      contract,
      actions,
      push: (name, payload) => this.pushEvent(name, payload),
      confirm: text => window.confirm(text),
      announce: () => window.dispatchEvent(new CustomEvent("annuart:tx")),
      failed: () => window.dispatchEvent(new CustomEvent("annuart:tx-failed")),
      now: () => Math.floor(Date.now() / 1000),
      target: window,
    });
  },
  // Called by LiveView when this ignored region's data attributes change.
  updated() {
    this.controller?.attributesChanged();
  },
  destroyed() {
    this.controller?.destroy();
  },
};
