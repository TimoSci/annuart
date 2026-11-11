// Brightness belongs to the activity history alone (hooks/activity.js sets
// --lvl on [data-activity-id] elements; app.css turns it into colour). No
// other state, such as hover or focus, may change those elements' background
// or text colour.
import test from "node:test";
import assert from "node:assert/strict";
import {readFileSync} from "node:fs";

const css = readFileSync(new URL("../css/app.css", import.meta.url), "utf8").replace(/\/\*[\s\S]*?\*\//g, "");

// Top-level rules as [selector, declarations]; @media blocks are opened up.
function rules(text) {
  const out = [];
  const re = /([^{}]+)\{([^{}]*)\}/g;
  const flat = text.replace(/@media[^{]*\{/g, "");
  let m;
  while ((m = re.exec(flat))) out.push([m[1].trim(), m[2]]);
  return out;
}

// The classes the templates put on activity areas: nav items, panels and rows.
const AREA = /\.nav-item|\.panel|\.row|\.area|\[data-activity-id\]/;
const STATE = /:hover|:focus|:active/;

test("hover, focus and active never change an activity area's brightness", () => {
  const offending = [];
  for (const [selectors, body] of rules(css)) {
    for (const selector of selectors.split(",").map(s => s.trim())) {
      // The state must apply to the area itself, not to something inside it.
      const last = selector.split(/\s+|>/).filter(Boolean).at(-1) ?? "";
      if (!STATE.test(last) || !AREA.test(last)) continue;
      if (/(^|;|\s)(background(-color)?|color)\s*:/.test(body)) offending.push(selector);
    }
  }
  assert.deepEqual(offending, []);
});

test("a hovered list row is marked by an outline", () => {
  const hover = rules(css).find(([s]) => s.split(",").some(x => x.trim() === ".rows .row:hover"));
  assert.ok(hover, "no .rows .row:hover rule");
  assert.match(hover[1], /outline\s*:/);
});
