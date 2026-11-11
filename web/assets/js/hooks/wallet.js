// The wallet control inside #wallet. LiveView leaves #wallet alone
// (phx-update="ignore") and tears the hook down on live navigation to another
// LiveView, so every mount builds its DOM from scratch out of the module-level
// session in chain/signer.js, and tells the new LiveView the address again.
import {availableSigners, connect, current, disconnect, onChange} from "../chain/signer.js";

const KEY = "annuart:signer";

const remembered = () => {
  try { return JSON.parse(localStorage.getItem(KEY)); } catch { return null; }
};
const remember = choice => {
  try {
    if (choice) localStorage.setItem(KEY, JSON.stringify(choice));
    else localStorage.removeItem(KEY);
  } catch { /* storage unavailable: the choice just is not remembered */ }
};

export const shorten = address => `${address.slice(0, 6)}…${address.slice(-4)}`;

const el = (tag, props = {}, ...children) => {
  const node = Object.assign(document.createElement(tag), props);
  node.append(...children);
  return node;
};

let reconnecting = null;

export const Wallet = {
  mounted() {
    this.message = "";
    this.off = onChange(() => {
      this.message = "";
      this.render();
      this.push();
    });
    this.render();
    this.push();
    this.reconnect();
  },

  destroyed() {
    this.off?.();
  },

  push() {
    this.pushEvent("wallet:changed", {address: current()?.address ?? null});
  },

  // Re-establish last visit's choice without prompting. One attempt at a time:
  // each navigation mounts a new hook.
  reconnect() {
    const choice = remembered();
    if (current() || reconnecting || !choice) return;
    reconnecting = this.connectWith(choice, {silent: true}).finally(() => { reconnecting = null; });
  },

  async connectWith({id, index}, {silent = false} = {}) {
    try {
      const session = await connect(id, id === "dev" ? {index} : {silent});
      if (session) remember({id, index});
      else if (silent) remember(null);
    } catch (error) {
      this.message = error.message;
      this.render();
    }
  },

  render() {
    const signers = availableSigners();
    const session = current();
    const children = [];

    if (signers.length === 0) {
      children.push(el("span", {className: "wallet-note"}, "Not configured"));
    } else if (session) {
      children.push(el("span", {className: "wallet-address", title: session.address}, shorten(session.address)));
      if (session.kind === "dev") children.push(this.devSelect(session));
      else children.push(el("button", {
        type: "button", className: "wallet-disconnect", textContent: "Disconnect",
        onclick: () => { remember(null); disconnect(); },
      }));
    } else if (signers.some(s => s.id === "dev")) {
      children.push(this.devSelect(null));
    } else {
      children.push(el("button", {
        type: "button", className: "wallet-connect", textContent: "Connect wallet",
        onclick: () => this.connectWith({id: "wallet"}),
      }));
    }

    if (this.message) children.push(el("span", {className: "wallet-note", role: "alert"}, this.message));
    this.el.replaceChildren(...children);
  },

  devSelect(session) {
    const accounts = window.__annuartDev.accounts;
    const select = el("select", {className: "wallet-dev", ariaLabel: "Dev account"});
    select.append(el("option", {value: "", textContent: "Not connected"}));
    accounts.forEach((address, i) =>
      select.append(el("option", {value: String(i), textContent: `Account ${i} · ${shorten(address)}`})));
    select.value = session ? String(accounts.indexOf(session.address)) : "";
    select.onchange = () => {
      if (select.value === "") { remember(null); disconnect(); }
      else this.connectWith({id: "dev", index: Number(select.value)});
    };
    return select;
  },
};
