// A value only its owner can read: hidden until revealed in the browser by a
// decryption, never sent to the server. Logic in SecretController (testable
// without LiveView); SecretValue is the LiveView hook around it.
import {formatAmount, unitPerDay} from "../units.js";
import {explain} from "../errors.js";
import {current, onChange, chainInfo} from "../chain/signer.js";
import {revealDistribution, revealBalance, revealTxAmount, revealRate} from "../chain/actions.js";

const HIDDEN = "•••••";

export class SecretController {
  constructor(el, deps) {
    this.el = el;
    this.deps = deps;
    this.doc = el.ownerDocument;
    this.shown = null;
    this.note = "";
    this.pending = null;
    // Bumped whenever the value is hidden or reset, so a decryption started
    // before then is discarded when it finishes.
    this.generation = 0;
    this.revealing = false;
    this.onReset = () => this.hide();
    deps.target.addEventListener("annuart:tx", this.onReset);
    // A new account, chain or disconnect: nothing revealed may stay on screen.
    this.unsubscribe = deps.onSession?.(this.onReset);
    this.render();
  }

  destroy() {
    this.deps.target.removeEventListener("annuart:tx", this.onReset);
    if (typeof this.unsubscribe === "function") this.unsubscribe();
    this.generation += 1;
  }

  hide() {
    this.generation += 1;
    this.revealing = false;
    this.shown = null;
    this.note = "";
    this.render();
  }

  toggle() {
    if (this.revealing) return this.pending;
    if (this.shown !== null) this.hide();
    else this.pending = this.reveal();
    return this.pending;
  }

  async reveal() {
    const {secret, label, id, tx, decimals, symbol} = this.el.dataset;
    const session = this.deps.session();
    if (!session) { this.note = "Connect a wallet first."; this.render(); return; }
    const contract = this.deps.contract(label);
    if (!contract || decimals === undefined || decimals === "") {
      this.note = "Token details are unavailable.";
      this.render();
      return;
    }
    this.note = "Revealing…";
    this.revealing = true;
    const generation = this.generation;
    this.render();
    try {
      let value;
      if (secret === "balance") value = await this.deps.reveal.balance(session, contract);
      else if (secret === "tx") value = await this.deps.reveal.tx(session, contract, tx);
      else if (secret === "rate") value = await this.deps.reveal.rate(session, contract, BigInt(id));
      else value = await this.deps.reveal.distribution(session, contract, BigInt(id));
      if (generation !== this.generation) return;
      this.note = "";
      if (secret === "rate") this.shown = `${unitPerDay(value, Number(decimals))} ${symbol ?? ""}`.trim() + " / day at 100%";
      else this.shown = `${formatAmount(value, Number(decimals))} ${symbol ?? ""}`.trim();
    } catch (err) {
      if (generation !== this.generation) return;
      this.note = explain(err);
    }
    this.revealing = false;
    this.render();
  }

  render() {
    const value = this.doc.createElement("span");
    value.className = "secret-value";
    value.textContent = this.shown ?? HIDDEN;
    const button = this.doc.createElement("button");
    button.type = "button";
    button.className = "clear";
    button.textContent = this.shown !== null ? "Hide" : "Reveal";
    button.onclick = () => this.toggle();
    const children = [value, button];
    if (this.note) {
      const note = this.doc.createElement("span");
      note.className = "note";
      note.textContent = this.note;
      children.push(note);
    }
    this.el.replaceChildren(...children);
  }
}

export const SecretValue = {
  mounted() {
    this.controller = new SecretController(this.el, {
      session: current,
      onSession: onChange,
      contract: label => chainInfo().contracts.find(c => c.label === label),
      reveal: {distribution: revealDistribution, balance: revealBalance, tx: revealTxAmount, rate: revealRate},
      target: window,
    });
  },
  destroyed() {
    this.controller?.destroy();
  },
};
