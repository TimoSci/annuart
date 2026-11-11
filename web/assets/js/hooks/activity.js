// Applies the activity brightness (../activity.js) to the page. <body> sits in
// the root layout, outside any LiveView, so this is not a LiveView hook:
// initActivity() runs once from app.js with document-level listeners.
//
// It sets --lvl on every [data-activity-id] after every DOM change, in the
// observer's microtask, so a node LiveView just replaced is painted at its
// level before the browser draws it. The history lives only in this browser
// and is never sent to the server.
import {touch, level, storageFor, load, save} from "../activity.js";

const SELECTOR = "[data-activity-id]";
const TEXT_ENTRY = "input, textarea, select, [contenteditable]";

export class ActivityController {
  constructor({doc, target, session, onSession, chainId, storages, observe}) {
    this.doc = doc;
    this.target = target;
    this.deps = {session, chainId, storages};
    this.where = this.locate();
    this.history = this.readHistory();

    this.onClick = e => this.activate(e.target, true);
    this.onKey = e => {
      if (e.key !== "Enter" && e.key !== " " && e.key !== "Spacebar") return;
      if (e.target?.closest?.(TEXT_ENTRY)) return;
      this.activate(e.target, false);
    };
    this.repaint = () => this.paint();
    doc.addEventListener("click", this.onClick);
    doc.addEventListener("keydown", this.onKey);
    target.addEventListener("phx:page-loading-stop", this.repaint);
    this.stopObserving = observe?.(this.repaint);
    this.stopSession = onSession?.(() => this.switchHistory());
    this.paint();
  }

  locate() {
    const s = this.deps.session?.() ?? null;
    return storageFor({chainId: s?.chainId ?? this.deps.chainId?.(), address: s?.address});
  }

  storage() {
    try {
      return this.deps.storages[this.where.area]?.() ?? null;
    } catch {
      return null;
    }
  }

  readHistory() {
    return load(this.storage(), this.where.key);
  }

  activate(node, isClick) {
    const el = node?.closest?.("#clear-activity, " + SELECTOR);
    if (!el) return;
    if (el.id === "clear-activity") {
      if (isClick) this.clear();
      return;
    }
    this.history = touch(this.history, el.dataset.activityId);
    save(this.storage(), this.where.key, this.history);
    this.paint();
  }

  clear() {
    this.history = [];
    save(this.storage(), this.where.key, this.history);
    this.paint();
  }

  // The wallet changed: show the history that belongs to it, merging nothing.
  switchHistory() {
    this.where = this.locate();
    this.history = this.readHistory();
    this.paint();
  }

  paint() {
    for (const el of this.doc.querySelectorAll(SELECTOR)) {
      const value = String(level(this.history, el.dataset.activityId));
      // Skipping an unchanged value keeps our own writes from re-triggering the observer.
      if (el.style.getPropertyValue("--lvl") !== value) el.style.setProperty("--lvl", value);
    }
  }

  destroy() {
    this.doc.removeEventListener("click", this.onClick);
    this.doc.removeEventListener("keydown", this.onKey);
    this.target.removeEventListener("phx:page-loading-stop", this.repaint);
    this.stopObserving?.();
    this.stopSession?.();
  }
}

export function initActivity({doc = document, target = window, signer}) {
  const observe = fn => {
    const observer = new target.MutationObserver(fn);
    // style is watched too: a patch can strip the --lvl we set on a surviving element.
    observer.observe(doc.documentElement, {
      childList: true, subtree: true, attributes: true, attributeFilter: ["data-activity-id", "style"],
    });
    return () => observer.disconnect();
  };
  const web = area => () => {
    try {
      return target[area];
    } catch {
      return null;
    }
  };
  return new ActivityController({
    doc, target, observe,
    session: signer.current,
    onSession: signer.onChange,
    chainId: () => signer.chainInfo().chainId,
    storages: {session: web("sessionStorage"), local: web("localStorage")},
  });
}
