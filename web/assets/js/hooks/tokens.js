// The Tokens page. Each card's frame, balance, faucet, authorise, wrap and
// unwrap controls are rendered by TokensLive; this fills in what only the
// browser can read (authorisation, ETH and WETH balances, unwraps still to be
// finished) and draws the actions that exist only for some wallets' state.
// Logic lives in TokensController, which takes its collaborators as arguments
// so it can be tested without LiveView; Tokens is the thin LiveView hook.
//
// Everything drawn from chain data is set as text, never as HTML.
import {formatAmount} from "../units.js";
import {current, onChange, chainInfo} from "../chain/signer.js";
import * as actions from "../chain/actions.js";
import {TxActionController} from "./tx_action.js";

const ETH_DECIMALS = 18;
const UNFINISHED_NOTE = "These were requested but not completed. Finishing one returns its amount as ETH.";
const WETH_NOTE = "Left over from an interrupted wrap or unwrap.";

const setHidden = (node, hidden) => {
  if (hidden) node.setAttribute("hidden", ""); else node.removeAttribute("hidden");
};

const shortId = id => (id.length > 18 ? `${id.slice(0, 10)}…${id.slice(-6)}` : id);

function dateText(seconds) {
  return new Date(seconds * 1000).toLocaleDateString("en-GB", {day: "numeric", month: "long", year: "numeric"});
}

export class TokensController {
  constructor(el, deps) {
    this.el = el;
    this.deps = deps;
    this.doc = el.ownerDocument;
    this.dynamic = [];
    this.pending = null;
    this.generation = 0;
    this.wrapped = el.dataset.kind === "wrapped";
    this.onTx = () => this.refresh();
    deps.target.addEventListener("annuart:tx", this.onTx);
    this.unsubscribe = deps.onSession?.(() => this.refresh());
    this.refresh();
  }

  destroy() {
    this.deps.target.removeEventListener("annuart:tx", this.onTx);
    if (typeof this.unsubscribe === "function") this.unsubscribe();
    this.clearActions();
  }

  role(name) { return this.el.querySelector(`[data-role=${name}]`); }

  // The promises of the actions drawn by this controller, for tests to await.
  get pendingActions() { return this.dynamic.map(c => c.pending).filter(Boolean); }

  clearActions() {
    this.dynamic.forEach(c => c.destroy());
    this.dynamic = [];
  }

  refresh() {
    this.pending = this.load();
    return this.pending;
  }

  async load() {
    const generation = ++this.generation;
    const session = this.deps.session();
    const contract = this.deps.contract(this.el.dataset.label);
    const data = {};
    if (session && contract) {
      const {reads} = this.deps;
      const read = async (name, fn) => {
        try { data[name] = {value: await fn()}; } catch { data[name] = {failed: true}; }
      };
      const tasks = [read("auth", () => reads.operatorStatus(session, contract))];
      if (this.wrapped) {
        tasks.push(
          read("eth", () => reads.ethBalance(session)),
          read("unwraps", () => reads.pendingUnwraps(session, contract)),
          read("weth", () => reads.wethBalance(session, contract)),
        );
      }
      await Promise.all(tasks);
    }
    // A newer refresh has started: its result is the one to show.
    if (generation !== this.generation) return;
    this.render(data, Boolean(session && contract));
  }

  render(data, connected) {
    this.renderAuthorisation(data.auth, connected);
    if (!this.wrapped) return;
    const eth = this.role("eth-balance");
    if (eth) eth.textContent = data.eth?.value !== undefined ? `${formatAmount(data.eth.value, ETH_DECIMALS)} ETH` : "";
    this.clearActions();
    this.renderUnwraps(data.unwraps?.value ?? []);
    this.renderWeth(data.weth?.value ?? 0n);
  }

  renderAuthorisation(auth, connected) {
    const node = this.role("authorisation");
    if (!node) return;
    if (!connected) node.textContent = "";
    else if (!auth || auth.failed) node.textContent = "Authorisation unavailable.";
    else if (!auth.value.authorised) node.textContent = "Not authorised";
    else node.textContent = auth.value.until ? `Authorised until ${dateText(auth.value.until)}` : "Authorised";
  }

  // A <div class="tx"> in the markup TxActionController expects, with its
  // arguments fixed by `args` rather than read from inputs.
  addAction(parent, {action, label, args}) {
    const wrap = this.doc.createElement("div");
    wrap.className = "tx";
    wrap.dataset.action = action;
    wrap.dataset.label = this.el.dataset.label;
    const button = this.doc.createElement("button");
    button.type = "button";
    button.className = "tx-run";
    button.dataset.role = "run";
    button.textContent = label;
    const steps = this.doc.createElement("ol");
    steps.className = "steps";
    wrap.append(button, steps);
    parent.append(wrap);
    const tx = this.deps.tx;
    this.dynamic.push(new TxActionController(wrap, {
      ...tx,
      actions: {[action]: (session, contract, _inputs, onStep) => tx.actions[action](session, contract, args, onStep)},
    }));
  }

  text(tag, text, className) {
    const node = this.doc.createElement(tag);
    node.textContent = text;
    if (className) node.className = className;
    return node;
  }

  renderUnwraps(list) {
    const section = this.role("unwraps");
    if (!section) return;
    section.replaceChildren();
    setHidden(section, list.length === 0);
    if (list.length === 0) return;
    section.append(this.text("h3", "Unfinished unwraps"));
    for (const {requestId} of list) {
      const row = this.doc.createElement("div");
      row.className = "field";
      row.append(this.text("span", `Request ${shortId(requestId)}`));
      section.append(row);
      this.addAction(row, {action: "finaliseUnwrap", label: "Finish unwrap", args: {requestId}});
    }
    section.append(this.text("p", UNFINISHED_NOTE, "note"));
  }

  renderWeth(balance) {
    const line = this.role("weth");
    if (!line) return;
    line.replaceChildren();
    setHidden(line, balance <= 0n);
    if (balance <= 0n) return;
    line.append(this.text("span", `WETH in your wallet: ${formatAmount(balance, ETH_DECIMALS)} WETH`));
    this.addAction(line, {action: "withdrawWeth", label: "Convert to ETH", args: {wei: balance}});
    line.append(this.text("p", WETH_NOTE, "note"));
  }
}

export const Tokens = {
  mounted() {
    this.controller = new TokensController(this.el, {
      session: current,
      onSession: onChange,
      contract: label => chainInfo().contracts.find(c => c.label === label),
      reads: actions,
      tx: {
        push: (name, payload) => this.pushEvent(name, payload),
        session: current,
        contract: label => chainInfo().contracts.find(c => c.label === label),
        actions,
        confirm: text => window.confirm(text),
        announce: () => window.dispatchEvent(new CustomEvent("annuart:tx")),
      },
      target: window,
    });
  },
  destroyed() {
    this.controller?.destroy();
  },
};
