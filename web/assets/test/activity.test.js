import test from "node:test";
import assert from "node:assert/strict";
import {parseHTML} from "linkedom";
import {STEPS, MAX_ITEMS, touch, level, storageFor, load, save} from "../js/activity.js";
import {ActivityController} from "../js/hooks/activity.js";

test("constants", () => {
  assert.equal(STEPS, 8);
  assert.equal(MAX_ITEMS, 50);
});

test("touch moves the id to the front without duplicates", () => {
  assert.deepEqual(touch(["a", "b", "c"], "c"), ["c", "a", "b"]);
  assert.deepEqual(touch([], "a"), ["a"]);
});

test("touch does not mutate its input", () => {
  const h = ["a", "b"];
  touch(h, "b");
  assert.deepEqual(h, ["a", "b"]);
});

test("level falls one step per other click and reaches zero after 8", () => {
  let h = touch([], "x");
  assert.equal(level(h, "x"), 1);
  for (let i = 0; i < 4; i++) h = touch(h, "o" + i);
  assert.equal(level(h, "x"), 0.5);
  for (let i = 4; i < 8; i++) h = touch(h, "o" + i);
  assert.equal(level(h, "x"), 0);
  assert.equal(level(h, "never"), 0);
});

test("clicking the same item repeatedly does not dim the others", () => {
  let h = touch(touch([], "b"), "a");
  const before = level(h, "b");
  h = touch(touch(h, "a"), "a");
  assert.equal(level(h, "b"), before);
  assert.equal(before, 1 - 1 / STEPS);
});

test("history is capped at 50", () => {
  let h = [];
  for (let i = 0; i < 80; i++) h = touch(h, "id" + i);
  assert.equal(h.length, 50);
  assert.equal(h[0], "id79");
  assert.equal(h[49], "id30");
});

test("storageFor: session without a wallet, local and per-address with one", () => {
  assert.deepEqual(storageFor({chainId: 31337, address: null}), {area: "session", key: "annuart:activity:session"});
  assert.deepEqual(storageFor({}), {area: "session", key: "annuart:activity:session"});
  assert.deepEqual(storageFor({chainId: 31337, address: "0xAbC"}), {area: "local", key: "annuart:activity:31337:0xabc"});
});

function memoryStorage() {
  const m = new Map();
  return {getItem: k => (m.has(k) ? m.get(k) : null), setItem: (k, v) => m.set(k, String(v)), removeItem: k => m.delete(k), m};
}

test("load and save round-trip", () => {
  const s = memoryStorage();
  save(s, "k", ["a", "b"]);
  assert.deepEqual(load(s, "k"), ["a", "b"]);
  assert.deepEqual(load(s, "other"), []);
});

test("load tolerates corrupt JSON and a throwing storage", () => {
  const s = memoryStorage();
  s.setItem("k", "{not json");
  assert.deepEqual(load(s, "k"), []);
  s.setItem("k", JSON.stringify({a: 1}));
  assert.deepEqual(load(s, "k"), []);
  s.setItem("k", JSON.stringify(["a", 3, null, "b"]));
  assert.deepEqual(load(s, "k"), ["a", "b"]);
  const bad = {getItem() { throw new Error("blocked"); }, setItem() { throw new Error("full"); }};
  assert.deepEqual(load(bad, "k"), []);
  assert.doesNotThrow(() => save(bad, "k", ["a"]));
  assert.deepEqual(load(null, "k"), []);
  assert.doesNotThrow(() => save(undefined, "k", ["a"]));
});

const PAGE = `<html><body>
  <header id="hdr" data-activity-id="header"><a id="nav" data-activity-id="nav:browse">Browse</a><button id="clear-activity">Clear</button></header>
  <main>
    <div id="outer" data-activity-id="panel:outer"><div id="inner" data-activity-id="panel:inner"><span id="leaf">x</span></div></div>
    <div id="a" data-activity-id="enft:mock:1"><b id="a-child">1</b></div>
    <div id="b" data-activity-id="enft:mock:2"></div>
    <div id="plain"></div>
  </main></body></html>`;

function make(opts = {}) {
  const {document, window} = parseHTML(PAGE);
  const sess = memoryStorage();
  const local = memoryStorage();
  const state = {session: opts.session ?? null, chainId: 31337};
  const listeners = new Set();
  const observers = [];
  const ctl = new ActivityController({
    doc: document,
    target: window,
    session: () => state.session,
    onSession: fn => { listeners.add(fn); return () => listeners.delete(fn); },
    chainId: () => state.chainId,
    storages: {session: () => opts.sessionStorage ?? sess, local: () => opts.localStorage ?? local},
    observe: fn => { observers.push(fn); return () => {}; },
  });
  const change = session => { state.session = session; listeners.forEach(fn => fn(session)); };
  const lvl = id => document.getElementById(id).style.getPropertyValue("--lvl") ?? "";
  const click = id => document.getElementById(id).dispatchEvent(new window.Event("click", {bubbles: true}));
  return {document, window, sess, local, ctl, change, lvl, click, observers, listeners};
}

test("a click brightens the area, others stay at rest, everything is painted at start", () => {
  const t = make();
  assert.equal(t.lvl("a"), "0");
  t.click("a-child");
  assert.equal(t.lvl("a"), "1");
  assert.equal(t.lvl("b"), "0");
  t.click("b");
  assert.equal(t.lvl("b"), "1");
  assert.equal(t.lvl("a"), "0.875");
});

test("a click inside nested areas brightens only the nearest one", () => {
  const t = make();
  t.click("leaf");
  assert.equal(t.lvl("inner"), "1");
  assert.equal(t.lvl("outer"), "0");
});

test("a click outside any area, or on the clear button, is not activity", () => {
  const t = make();
  t.click("a");
  t.click("plain");
  t.click("clear-activity");
  assert.equal(t.lvl("a"), "0");
  assert.equal(t.lvl("hdr"), "0");
  assert.equal(t.sess.getItem("annuart:activity:session"), "[]");
});

test("Enter and Space on an area count, other keys and text entry do not", () => {
  const t = make();
  const key = (id, k) => t.document.getElementById(id).dispatchEvent(new t.window.Event("keydown", {bubbles: true}));
  const press = (id, k) => {
    const e = new t.window.Event("keydown", {bubbles: true});
    e.key = k;
    t.document.getElementById(id).dispatchEvent(e);
  };
  void key;
  press("a", "Tab");
  assert.equal(t.lvl("a"), "0");
  press("a", "Enter");
  assert.equal(t.lvl("a"), "1");
  press("b", " ");
  assert.equal(t.lvl("b"), "1");
  assert.equal(t.lvl("a"), "0.875");
  t.document.getElementById("a").innerHTML = '<input id="i">';
  press("i", " ");
  press("i", "Enter");
  assert.equal(t.lvl("b"), "1");
});

test("the history is saved to session storage without a wallet and holds ids only", () => {
  const t = make();
  t.click("a");
  t.click("b");
  assert.deepEqual(JSON.parse(t.sess.getItem("annuart:activity:session")), ["enft:mock:2", "enft:mock:1"]);
  assert.equal(t.local.m.size, 0);
});

test("the page remembers: a new controller starts from the saved history", () => {
  const t = make();
  t.click("a");
  const again = new ActivityController({
    doc: t.document, target: t.window, session: () => null, onSession: () => () => {}, chainId: () => 31337,
    storages: {session: () => t.sess, local: () => t.local}, observe: () => () => {},
  });
  void again;
  assert.equal(t.lvl("a"), "1");
});

test("the hook repaints levels after a LiveView update", () => {
  const t = make();
  t.click("a");
  const fresh = t.document.createElement("div");
  fresh.id = "a2";
  fresh.setAttribute("data-activity-id", "enft:mock:1");
  t.document.getElementById("a").replaceWith(fresh);
  assert.equal(t.lvl("a2"), "");
  t.observers.forEach(fn => fn());
  assert.equal(t.lvl("a2"), "1");
  // a patch that stripped the style off a surviving element
  t.document.getElementById("b").removeAttribute("style");
  t.window.dispatchEvent(new t.window.Event("phx:page-loading-stop"));
  assert.equal(t.lvl("b"), "0");
  t.click("b");
  t.document.getElementById("a2").removeAttribute("style");
  t.window.dispatchEvent(new t.window.Event("phx:page-loading-stop"));
  assert.equal(t.lvl("a2"), "0.875");
});

test("switching wallet swaps histories without merging", () => {
  const t = make();
  t.click("a");
  t.change({address: "0xAA", chainId: 5});
  assert.equal(t.lvl("a"), "0");
  t.click("b");
  assert.deepEqual(JSON.parse(t.local.getItem("annuart:activity:5:0xaa")), ["enft:mock:2"]);
  t.change({address: "0xBB", chainId: 5});
  assert.equal(t.lvl("b"), "0");
  t.change({address: "0xaa", chainId: 5});
  assert.equal(t.lvl("b"), "1");
  assert.equal(t.lvl("a"), "0");
  t.change(null);
  assert.equal(t.lvl("a"), "1");
  assert.equal(t.lvl("b"), "0");
  assert.deepEqual(JSON.parse(t.sess.getItem("annuart:activity:session")), ["enft:mock:1"]);
});

test("clear empties only the active history", () => {
  const t = make();
  t.click("a");
  t.change({address: "0xAA", chainId: 5});
  t.click("b");
  t.click("clear-activity");
  assert.equal(t.lvl("b"), "0");
  assert.equal(t.local.getItem("annuart:activity:5:0xaa"), "[]");
  assert.deepEqual(JSON.parse(t.sess.getItem("annuart:activity:session")), ["enft:mock:1"]);
});

test("a storage that throws on write does not break the page", () => {
  const bad = {getItem: () => null, setItem() { throw new Error("quota"); }};
  const t = make({sessionStorage: bad});
  assert.doesNotThrow(() => t.click("a"));
  assert.equal(t.lvl("a"), "1");
  t.click("b");
  assert.equal(t.lvl("a"), "0.875");
  assert.doesNotThrow(() => t.click("clear-activity"));
  assert.equal(t.lvl("a"), "0");
});

test("a storage accessor that throws leaves the page working", () => {
  const {document, window} = parseHTML(PAGE);
  const ctl = new ActivityController({
    doc: document, target: window, session: () => null, onSession: () => () => {}, chainId: () => 1,
    storages: {session: () => { throw new Error("blocked"); }, local: () => { throw new Error("blocked"); }},
    observe: () => () => {},
  });
  document.getElementById("a").dispatchEvent(new window.Event("click", {bubbles: true}));
  assert.equal(document.getElementById("a").style.getPropertyValue("--lvl"), "1");
  ctl.destroy();
});

test("destroy stops listening", () => {
  const t = make();
  t.ctl.destroy();
  assert.equal(t.listeners.size, 0);
  t.click("a");
  assert.equal(t.lvl("a"), "0");
});
