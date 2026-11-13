import test from "node:test";
import assert from "node:assert/strict";
import {parseHTML} from "linkedom";
import {accountFrame, applyFrame} from "../js/frame.js";

const ACCOUNT = "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266";
// The same string Annuart.Randomart.frame/1 gives (test/annuart/randomart_test.exs).
const FRAME = "conic-gradient(hsl(359 45% 64%) 0% 10%, hsl(17 45% 48%) 10% 20%, hsl(323 45% 48%) 20% 30%, " +
  "hsl(323 45% 56%) 30% 40%, hsl(17 45% 56%) 40% 50%, hsl(323 45% 40%) 50% 60%, hsl(305 45% 56%) 60% 70%, " +
  "hsl(323 45% 64%) 70% 80%, hsl(305 45% 48%) 80% 90%, hsl(17 45% 56%) 90% 100%)";

test("an account's frame is ten muted segments from its address, the same as the server's", () => {
  assert.equal(accountFrame(ACCOUNT), FRAME);
  assert.equal(accountFrame(ACCOUNT.toLowerCase()), FRAME);
  assert.notEqual(accountFrame("0x70997970C51812dc3A010C7d01b50e0d17dc79C8"), FRAME);
});

test("something that is not an address has no frame", () => {
  for (const bad of [null, undefined, "", "0x1234", ACCOUNT + "00", "f39Fd6e51aad88F6F4ce6aB8827279cffFb92266", "0x" + "zz".repeat(20)])
    assert.equal(accountFrame(bad), null);
});

test("applyFrame marks the element and sets the frame, and leaves it alone for a bad address", () => {
  const {document} = parseHTML("<html><body><span id='a'></span><span id='b'></span></body></html>");
  const a = applyFrame(document.getElementById("a"), ACCOUNT);
  assert.ok(a.classList.contains("acct-frame"));
  assert.equal(a.style.getPropertyValue("--frame"), FRAME);
  const b = applyFrame(document.getElementById("b"), "nonsense");
  assert.equal(b.classList.contains("acct-frame"), false);
});
