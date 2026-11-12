// The Create ENFT form. Everything typed here stays in the browser: the amount
// is parsed, encrypted and sent to the chain by actions.createEnft, and the one
// event pushed to the server, "tx:confirmed", carries {action, label, tokenId,
// hash} and nothing else. Logic lives in CreateFormController, which takes its
// collaborators as arguments so it can be tested without LiveView; CreateForm
// is the thin LiveView hook around it.
import {isAddress} from "ethers";
import {
  parseAmount, formatAmount, effectiveRate, toSegments, scheduleTotal, amountWarning,
  ScheduleError, U64_MAX,
} from "../units.js";
import {explainAmount} from "../errors.js";
import {current, onChange, chainInfo} from "../chain/signer.js";
import {createEnft} from "../chain/actions.js";
import {nameProblem} from "../name.js";
import {StepList, START_OVER_QUESTION} from "./tx_action.js";

const ADDRESS = /^0x[0-9a-fA-F]{40}$/;
const ZERO_ADDRESS = /^0x0{40}$/;
const UNITS = ["days", "weeks", "months", "years"];
const PERS = ["day", "month", "year"];
// Largest first, for describing a length as one whole unit.
const LENGTH_UNITS = [["year", 31536000n], ["month", 2592000n], ["day", 86400n]];
const INDEFINITE_SHARE = 30;
const MIN_BAR_HEIGHT = 4;
// Dates beyond this are outside what a JavaScript Date can show.
const MAX_DATE_SECONDS = 8_640_000_000_000n;
// A start further off than this is called out in the summary (a year is 365 days).
const FAR_START_SECONDS = 10n * 31536000n;
// What the person typed is shown back without digit grouping, so "1,500" can
// never be read as one and a half; computed values keep it.
const TYPED = {grouping: false};

class InputError extends Error {}

const setHidden = (node, hidden) => {
  if (hidden) node.setAttribute("hidden", ""); else node.removeAttribute("hidden");
};

// `checked` is the live state in a browser; the attribute covers a DOM without it.
const isChecked = box => (box ? (box.checked ?? box.hasAttribute("checked")) === true : false);

function lengthText(seconds) {
  const [name, size] = LENGTH_UNITS.find(([, s]) => seconds % s === 0n) ?? ["second", 1n];
  const n = seconds / size;
  return `${n} ${name}${n === 1n ? "" : "s"}`;
}

function dateText(seconds, withTime = false) {
  if (seconds === null || seconds === undefined || seconds > MAX_DATE_SECONDS) return "a date far in the future";
  const date = new Date(Number(seconds) * 1000);
  const day = date.toLocaleDateString("en-GB", {day: "numeric", month: "long", year: "numeric"});
  if (!withTime) return day;
  return `${day}, ${date.toLocaleTimeString("en-GB", {hour: "2-digit", minute: "2-digit", hour12: false})}`;
}

function warningText(warning, {symbol, decimals}, format) {
  if (!warning) return "";
  switch (warning.kind) {
    case "stops_early":
      return `Your endowment is less than the schedule total. Payouts will stop early, around ${dateText(warning.at)}.`;
    case "leftover":
      return `${formatAmount(warning.extra, decimals, format)} ${symbol} extra will be paid to the owner as a lump sum when the schedule ends.`;
    default:
      return `At these rates the endowment runs out around ${dateText(warning.at)}.`;
  }
}

export class CreateFormController {
  constructor(el, deps) {
    this.el = el;
    this.deps = deps;
    this.doc = el.ownerDocument;
    this.running = false;
    this.ready = null;
    this.pending = null;
    this.locked = false;

    this.steps = new StepList(el.querySelector("ol.steps"));
    this.echo = this.doc.createElement("span");
    this.echo.className = "amount-echo";
    this.role("amount").after(this.echo);

    this.onChange = event => {
      if (event.target === this.role("token")) this.tokenChanged();
      if (event.target === this.role("start-mode")) setHidden(this.role("start-at"), this.role("start-mode").value !== "at");
      if (event.target === this.role("recipient-mode")) setHidden(this.role("recipient"), this.role("recipient-mode").value !== "other");
      if (event.target.dataset?.role === "indefinite") this.syncRows();
      this.edited();
    };
    this.onClick = event => {
      const button = event.target.closest?.("button[data-role]");
      if (!button || !this.el.contains(button) || button.disabled || button.hasAttribute("disabled")) return;
      switch (button.dataset.role) {
        case "add-period": this.addRow(); this.edited(); break;
        case "remove-period": button.closest("[data-role=period]").remove(); this.syncRows(); this.edited(); break;
        case "run": case "retry": case "start-over": this.run(); break;
        case "confirm": this.confirm(); break;
        case "cancel": this.cancel(); break;
      }
    };
    this.onSubmit = event => event.preventDefault();
    el.addEventListener("input", this.onChange);
    el.addEventListener("change", this.onChange);
    el.addEventListener("click", this.onClick);
    el.addEventListener("submit", this.onSubmit);

    // A different wallet makes a summary naming the old one untrue.
    this.unsubscribe = deps.onSession?.(() => this.cancel());

    setHidden(this.role("start-at"), true);
    setHidden(this.role("recipient"), true);
    setHidden(this.role("summary"), true);
    this.addRow();
    this.tokenChanged({announce: false});
  }

  destroy() {
    this.unsubscribe?.();
    for (const [name, fn] of [["input", this.onChange], ["change", this.onChange], ["click", this.onClick], ["submit", this.onSubmit]]) {
      this.el.removeEventListener(name, fn);
    }
  }

  role(name) { return this.el.querySelector(`[data-role=${name}]`); }
  say(text) { this.role("message").textContent = text; }

  // The selected token: label, symbol and decimals (null when unknown).
  token() {
    const holder = this.role("token");
    let source = holder;
    if (holder.tagName === "SELECT") {
      const options = [...holder.querySelectorAll("option")];
      source = options.find(o => o.value === holder.value) ?? options[0];
    }
    const label = source.dataset.label ?? source.value;
    const raw = source.dataset.decimals;
    const decimals = raw === undefined || raw === "" ? null : Number(raw);
    return {label, symbol: source.dataset.symbol ?? "", decimals};
  }

  tokenChanged({announce = true} = {}) {
    const {label, symbol, decimals} = this.token();
    const balance = this.role("balance");
    if (balance) {
      balance.dataset.label = label;
      balance.dataset.symbol = symbol;
      balance.dataset.decimals = decimals ?? "";
      // A balance revealed for the previous token must not stay on screen.
      if (announce) this.deps.announce();
    }
    this.tokenSymbols();
  }

  // Schedule rows

  periods() { return [...this.el.querySelectorAll("[data-role=period]")]; }

  readRow(row) {
    const get = name => row.querySelector(`[data-role=${name}]`);
    return {
      length: get("length").value,
      unit: get("unit").value,
      rate: get("rate").value,
      per: get("per").value,
      indefinite: isChecked(get("indefinite")),
    };
  }

  addRow() {
    const doc = this.doc;
    const make = (tag, {role, className, ...attrs} = {}, text) => {
      const node = doc.createElement(tag);
      if (className) node.className = className;
      if (role) node.dataset.role = role;
      for (const [name, value] of Object.entries(attrs)) node.setAttribute(name, value);
      if (text !== undefined) node.textContent = text;
      return node;
    };
    const select = (role, values, chosen = values[0]) => {
      const node = make("select", {role});
      for (const v of values) {
        const option = make("option", {value: v}, v);
        if (v === chosen) option.selected = true;
        node.append(option);
      }
      return node;
    };
    const row = make("div", {role: "period", className: "period"});
    const length = make("input", {role: "length", type: "text", placeholder: "Length"});
    length.setAttribute("inputmode", "numeric");
    length.setAttribute("autocomplete", "off");
    const rate = make("input", {role: "rate", type: "text", placeholder: "Amount"});
    rate.setAttribute("inputmode", "decimal");
    rate.setAttribute("autocomplete", "off");
    row.append(
      make("span", {className: "lbl"}, "Lasts"), length, select("unit", UNITS, "months"),
      make("span", {role: "indefinite-slot"}),
      make("span", {className: "lbl"}, "Pays"), rate,
      make("span", {role: "symbol"}), make("span", {className: "lbl"}, "per"), select("per", PERS),
      make("span", {role: "effective", className: "effective"}),
      make("span", {role: "upto", className: "upto"}),
      make("span", {role: "remove-slot"}),
    );
    this.role("periods").append(row);
    this.syncRows();
  }

  // Only the last row can be indefinite, and it starts out that way; a lone
  // row cannot be removed.
  syncRows() {
    const rows = this.periods();
    rows.forEach((row, i) => {
      const last = i === rows.length - 1;
      const slot = row.querySelector("[data-role=indefinite-slot]");
      let box = row.querySelector("[data-role=indefinite]");
      if (last && !box) {
        const label = this.doc.createElement("label");
        box = this.doc.createElement("input");
        box.type = "checkbox";
        box.dataset.role = "indefinite";
        // The last period runs indefinitely unless the person unticks it.
        box.checked = true;
        box.setAttribute("checked", "");
        label.append(box, " Indefinitely");
        slot.append(label);
      } else if (!last && box) {
        slot.replaceChildren();
        box = null;
      }
      const indefinite = isChecked(box);
      setHidden(row.querySelector("[data-role=length]"), indefinite);
      setHidden(row.querySelector("[data-role=unit]"), indefinite);

      const removeSlot = row.querySelector("[data-role=remove-slot]");
      const button = removeSlot.querySelector("button");
      if (rows.length > 1 && !button) {
        const b = this.doc.createElement("button");
        b.type = "button";
        b.dataset.role = "remove-period";
        b.textContent = "Remove";
        removeSlot.append(b);
      } else if (rows.length === 1 && button) {
        removeSlot.replaceChildren();
      }
    });
    this.tokenSymbols();
  }

  tokenSymbols() {
    const {symbol} = this.token();
    for (const node of this.el.querySelectorAll("[data-role=symbol]")) node.textContent = symbol;
  }

  // The name as it would be sent: trimmed, "" for none. The field is optional
  // in the markup too, so a page without it creates unnamed ENFTs.
  typedName() { return (this.role("name")?.value ?? "").trim(); }

  // Live display

  // An edit invalidates a summary that is waiting for confirmation.
  edited() {
    this.cancel();
    this.refresh();
  }

  refresh() {
    const {symbol, decimals} = this.token();
    const input = this.role("amount");
    const rows = this.periods().map(row => this.readRow(row));

    let amount = null;
    this.echo.textContent = "";
    if (input.value.trim() !== "") {
      try {
        if (decimals === null) throw new InputError("Token details are unavailable. Try again later.");
        amount = parseAmount(input.value, decimals);
        this.echo.textContent = `= ${formatAmount(amount, decimals, TYPED)} ${symbol}`.trim();
      } catch (err) {
        this.echo.textContent = err.message && err instanceof InputError ? err.message : explainAmount(err, symbol);
      }
    }

    const nameHint = this.role("name-hint");
    if (nameHint) nameHint.textContent = nameProblem(this.typedName()) ?? "";

    const valid = [];
    this.periods().forEach((row, i) => {
      const effective = row.querySelector("[data-role=effective]");
      const upto = row.querySelector("[data-role=upto]");
      effective.textContent = "";
      upto.textContent = "";
      if (decimals === null) return;
      let segment;
      try {
        segment = toSegments([rows[i]], decimals)[0];
      } catch (err) {
        if (rows[i].rate.trim() !== "" || rows[i].length.trim() !== "") effective.textContent = explainAmount(err, symbol);
        return;
      }
      valid.push(segment);
      effective.textContent = `= ${effectiveRate(segment.ratePerSec, rows[i].per, decimals, TYPED)} ${symbol} per ${rows[i].per}`;
      upto.textContent = segment.duration === U64_MAX
        ? "Pays until the endowment runs out"
        : `Up to ${formatAmount(segment.duration * segment.ratePerSec, decimals)} ${symbol}`;
    });

    this.drawChart(valid);
    this.role("total").textContent = "";
    this.role("warning").textContent = "";
    if (decimals === null || valid.length !== rows.length) return;

    let segments;
    try {
      segments = toSegments(rows, decimals);
    } catch (err) {
      this.role("total").textContent = explainAmount(err, symbol);
      return;
    }
    const total = scheduleTotal(segments);
    this.role("total").textContent = total === null
      ? "Schedule pays until the endowment runs out."
      : `Schedule pays up to ${formatAmount(total, decimals)} ${symbol} in total over ${lengthText(this.fixedSeconds(segments))}.`;

    if (amount !== null) {
      const now = BigInt(Math.floor(this.deps.now() / 1000));
      const start = this.chosenStart() ?? now;
      this.role("warning").textContent = warningText(amountWarning(segments, start, amount), {symbol, decimals});
    }
  }

  fixedSeconds(segments) {
    return segments.reduce((sum, s) => (s.duration === U64_MAX ? sum : sum + s.duration), 0n);
  }

  // Bars like the server's chart: width by length, height by rate.
  drawChart(segments) {
    const indefinite = segments.some(s => s.duration === U64_MAX);
    const fixedShare = indefinite ? 100 - INDEFINITE_SHARE : 100;
    const fixed = Number(this.fixedSeconds(segments));
    const maxRate = segments.reduce((m, s) => (s.ratePerSec > m ? s.ratePerSec : m), 0n);
    const pct = value => Math.round(value * 10) / 10;
    const bars = segments.map(s => {
      const open = s.duration === U64_MAX;
      const width = open ? INDEFINITE_SHARE : fixed === 0 ? 0 : pct(fixedShare * Number(s.duration) / fixed);
      const height = maxRate === 0n ? MIN_BAR_HEIGHT : Math.max(pct(100 * Number(s.ratePerSec) / Number(maxRate)), MIN_BAR_HEIGHT);
      const bar = this.doc.createElement("div");
      bar.className = open ? "bar open" : "bar";
      bar.dataset.role = "bar";
      if (open) bar.dataset.indefinite = "";
      bar.setAttribute("style", `width:${width}%;height:${height}%`);
      return bar;
    });
    this.role("chart").replaceChildren(...bars);
  }

  // Options

  // Unix seconds of the chosen start, or null for "Now". Throws when "On a
  // date" is selected without a usable date.
  chosenStart() {
    if (this.role("start-mode").value !== "at") return null;
    const ms = new Date(this.role("start-at").value).getTime();
    if (Number.isNaN(ms)) return null;
    return BigInt(Math.floor(ms / 1000));
  }

  // Validation: in order, stopping at the first failure.
  validate() {
    const session = this.deps.session();
    if (!session) throw new InputError("Connect a wallet first.");
    const {label, symbol, decimals} = this.token();
    const contract = this.deps.contract(label);
    if (!contract || decimals === null) throw new InputError("Token details are unavailable. Try again later.");

    let amount;
    try {
      amount = parseAmount(this.role("amount").value, decimals);
    } catch (err) {
      throw new InputError(explainAmount(err, symbol));
    }

    const name = this.typedName();
    const problem = nameProblem(name);
    if (problem) throw new InputError(problem);

    const rows = this.periods().map(row => this.readRow(row));
    rows.forEach((row, i) => {
      try { toSegments([row], decimals); } catch (err) { throw new InputError(`Period ${i + 1}: ${explainAmount(err, symbol)}`); }
    });
    let segments;
    try { segments = toSegments(rows, decimals); } catch (err) { throw new InputError(explainAmount(err, symbol)); }

    let to = session.address;
    const other = this.role("recipient-mode").value === "other";
    if (other) {
      to = this.role("recipient").value.trim();
      if (!ADDRESS.test(to) || !isAddress(to)) throw new InputError("Enter a valid address, starting with 0x.");
      if (ZERO_ADDRESS.test(to)) throw new InputError("Enter a valid address. The zero address is not allowed.");
    }

    const now = BigInt(Math.floor(this.deps.now() / 1000));
    let start = null;
    if (this.role("start-mode").value === "at") {
      start = this.chosenStart();
      if (start === null) throw new InputError("Choose a start date and time.");
      if (start <= now) throw new InputError("The start must be in the future.");
    }
    // The contract's own bound: where the schedule ends must fit in a uint64.
    if ((start ?? now) + this.fixedSeconds(segments) >= U64_MAX) {
      throw new InputError(explainAmount(new ScheduleError("too_long"), symbol));
    }

    return {
      args: {to, amount, segments, start: start ?? 0n, topUps: isChecked(this.role("donations")), name, symbol, decimals},
      label, symbol, decimals, contract, rows, other, now,
    };
  }

  summaryText({args, symbol, decimals, rows, other, now}) {
    const me = other ? args.to : `${args.to} (you)`;
    const startText = args.start === 0n
      ? "Payouts start as soon as the transaction is mined."
      : `Payouts start on ${dateText(args.start, true)}.`;
    const farStart = args.start !== 0n && args.start - now > FAR_START_SECONDS
      ? `Payouts do not start until ${dateText(args.start)}, more than ten years from now.`
      : "";
    const donations = args.topUps ? "Donations are allowed" : "Donations are not allowed";
    const words = rows.map((row, i) => {
      const rate = `${effectiveRate(args.segments[i].ratePerSec, row.per, decimals, TYPED)} ${symbol} per ${row.per}`;
      if (row.indefinite) return `${i === 0 ? "" : "then "}indefinitely at ${rate}`;
      const n = row.length.trim();
      const unit = Number(n) === 1 ? row.unit.replace(/s$/, "") : row.unit;
      return `${i === 0 ? "" : "then "}${n} ${unit} at ${rate}`;
    }).join(", ");
    const warning = warningText(amountWarning(args.segments, args.start === 0n ? now : args.start, args.amount), {symbol, decimals}, TYPED);
    return [
      `You are about to lock ${formatAmount(args.amount, decimals, TYPED)} ${symbol} in a new ENFT.`,
      args.name
        ? `It will be named "${args.name}". The name is public and cannot be changed later.`
        : "It will have no name, and one cannot be added later.",
      `The ENFT will belong to ${me}.`,
      startText,
      farStart,
      `${donations}, and this cannot be changed later.`,
      `The schedule is ${words}.`,
      warning,
      "The endowment cannot be taken back and the schedule cannot be changed.",
    ].filter(Boolean).join(" ");
  }

  // Create: validate, then show the summary and wait for an explicit
  // confirmation. After a failure that came once a transaction was sent, any
  // click first asks whether to send it again.
  run() {
    if (this.running || this.locked) return this.pending;
    if (this.steps.recovery?.kind === "start-over" && !this.deps.confirm(START_OVER_QUESTION)) return this.pending;
    this.pending = this.attempt();
    return this.pending;
  }

  async attempt() {
    if (this.running || this.locked) return;
    this.say("");
    this.cancel();
    let checked;
    try {
      checked = this.validate();
    } catch (err) {
      if (!(err instanceof InputError)) throw err;
      this.say(err.message);
      return;
    }
    this.ready = checked;
    const summary = this.role("summary");
    const text = this.doc.createElement("p");
    text.textContent = this.summaryText(checked);
    const confirm = this.doc.createElement("button");
    confirm.type = "button";
    confirm.dataset.role = "confirm";
    confirm.textContent = "Confirm and create";
    const cancel = this.doc.createElement("button");
    cancel.type = "button";
    cancel.dataset.role = "cancel";
    cancel.textContent = "Cancel";
    summary.replaceChildren(text, confirm, cancel);
    setHidden(summary, false);
  }

  cancel() {
    this.ready = null;
    const summary = this.role("summary");
    summary.replaceChildren();
    setHidden(summary, true);
  }

  confirm() {
    const ready = this.ready;
    if (!ready || this.running || this.locked) return;
    this.cancel();
    // The summary may have waited a while: a chosen start must still be ahead.
    if (ready.args.start !== 0n && ready.args.start <= BigInt(Math.floor(this.deps.now() / 1000))) {
      this.say("The start must be in the future.");
      return;
    }
    this.pending = this.execute(ready);
    return this.pending;
  }

  async execute({args, label, contract}) {
    const session = this.deps.session();
    if (!session) { this.say("Connect a wallet first."); return; }
    this.running = true;
    this.setBusy(true);
    this.steps.begin("createEnft");
    try {
      const result = await this.deps.createEnft(session, contract, args, (id, state, detail) => this.steps.report(id, state, detail));
      this.deps.push("tx:confirmed", {action: "createEnft", label, tokenId: String(result.tokenId), hash: result.hash});
      this.deps.announce();
      this.lock();
    } catch (err) {
      this.steps.fail(err);
    } finally {
      this.running = false;
      this.setBusy(false);
    }
  }

  // After a create the form stays as it is, so the same ENFT cannot be locked twice.
  lock() {
    this.locked = true;
    for (const node of this.el.querySelectorAll("input, select, button")) node.setAttribute("disabled", "");
    this.say("Created. Opening your ENFT…");
  }

  setBusy(busy) {
    const button = this.role("run");
    if (button && !this.locked) button.disabled = busy;
  }
}

export const CreateForm = {
  mounted() {
    this.controller = new CreateFormController(this.el, {
      push: (name, payload) => this.pushEvent(name, payload),
      session: current,
      onSession: onChange,
      contract: label => chainInfo().contracts.find(c => c.label === label),
      createEnft,
      announce: () => window.dispatchEvent(new CustomEvent("annuart:tx")),
      now: () => Date.now(),
      confirm: text => window.confirm(text),
    });
  },
  destroyed() {
    this.controller?.destroy();
  },
};
