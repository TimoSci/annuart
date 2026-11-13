import test from "node:test";
import assert from "node:assert/strict";
import { explain, explainAmount } from "../js/errors.js";
import { AmountError, ScheduleError } from "../js/units.js";

const table = {
  "0x4067fd1b": "This ENFT does not accept donations.",
  "0x30cd7471": "Only the owner can do this.",
  "0x528f27bf": "This ENFT's schedule has ended, so it no longer accepts donations.",
  "0x15a7d4e1": "This schedule runs too far into the future.",
  "0x21bb36f6": "Add at least one period.",
  "0x91378467": "Every period needs a length.",
  "0x8dba7587": "Only the last period can be indefinite.",
  "0x52c92d06": "An indefinite period needs a rate above zero.",
  "0xb1d04f08": "This ENFT does not exist.",
};

test("explain maps every selector in the table", () => {
  for (const [sel, msg] of Object.entries(table)) {
    assert.equal(explain({ data: sel }), msg);
    assert.equal(explain({ info: { error: { data: sel + "00".repeat(32) } } }), msg);
    assert.equal(explain({ error: { data: sel.toUpperCase().replace("0X", "0x") } }), msg);
  }
});

test("explain: user rejection and fallback", () => {
  const rejected = "You cancelled the request in your wallet.";
  assert.equal(explain({ code: 4001 }), rejected);
  assert.equal(explain({ code: "ACTION_REJECTED" }), rejected);
  assert.equal(explain({ code: "INSUFFICIENT_FUNDS" }), "Your wallet does not have enough ETH to pay for this transaction.");
  assert.equal(explain({ shortMessage: "boom" }), "The transaction failed: boom");
  assert.equal(explain(new Error("plain")), "The transaction failed: plain");
});

test("explainAmount", () => {
  assert.equal(explainAmount(new AmountError("rate_rounds_to_zero"), "USDC"), "This rate is too small to pay anything. Enter a larger rate.");
  assert.equal(explainAmount(new AmountError("too_many_decimals", 6), "USDC"), "Use at most 6 decimal places.");
  assert.equal(explainAmount(new AmountError("empty"), "USDC"), "Enter an amount.");
  assert.equal(explainAmount(new AmountError("separator"), "USDC"), "Use a period for decimals and no separators, for example 1500.25.");
  assert.equal(explainAmount(new ScheduleError("indefinite_not_last"), "USDC"), "Only the last period can be indefinite.");
  assert.equal(explainAmount(new ScheduleError("too_long"), "USDC"), "This schedule runs too far into the future.");
  assert.equal(explainAmount(new ScheduleError("empty"), "USDC"), "Add at least one period.");
});

test("explain passes an ActionError's message through as it is", async () => {
  const { ActionError } = await import("../js/errors.js");
  const err = new ActionError("Enter at least 1 unit.");
  assert.equal(err.name, "ActionError");
  assert.equal(explain(err), "Enter at least 1 unit.");
});

test("explain maps the automatic payout errors", () => {
  const sentences = {
    "0xa6db1522": "It is too soon for the next automatic payout.",       // PayoutTooSoon(uint64)
    "0xc2cf8023": "Automatic payouts are switched off for this ENFT.",  // AutoPayoutDisabled()
    "0xbef3c847": "A payout is already waiting to be finished.",        // PayoutPending()
    "0xf39d2840": "This ENFT has paid out everything.",                 // NothingLeft()
    "0xe52041f6": "The fee was lowered. Reload and try again.",         // FeeTooLow(uint128)
    "0x5fabb610": "The interval must be between 1 hour and 365 days.",  // InvalidInterval()
    "0x33f986e6": "Payouts have not started yet.",                      // ScheduleNotStarted()
    "0x645f76c6": "This payout has already been finished.",             // NoPendingPayout()
    "0x1c26714c": "The transaction ran out of gas. Try again.",         // InsufficientGas()
  };
  for (const [sel, msg] of Object.entries(sentences)) {
    assert.equal(explain({ data: sel + "00".repeat(32) }), msg);
    assert.equal(explain({ info: { error: { data: sel } } }), msg);
  }
  assert.equal(explainAmount(new ScheduleError("bad_interval"), "ETH"), "The interval must be between 1 hour and 365 days.");
});
