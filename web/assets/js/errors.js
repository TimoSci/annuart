// Turns wallet and contract failures into plain sentences.

// A failure whose message is already a plain sentence for the user.
export class ActionError extends Error {
  constructor(message) {
    super(message);
    this.name = "ActionError";
  }
}

const SELECTORS = {
  "0x4067fd1b": "This ENFT does not accept donations.",
  "0x30cd7471": "Only the owner can do this.",
  "0x528f27bf": "This ENFT's schedule has ended, so it no longer accepts donations.",
  "0x15a7d4e1": "This schedule runs too far into the future.",
  "0x21bb36f6": "Add at least one period.",
  "0x91378467": "Every period needs a length.",
  "0x8dba7587": "Only the last period can be indefinite.",
  "0x52c92d06": "An indefinite period needs a rate above zero.",
  "0xb1d04f08": "This ENFT does not exist.",
  // Automatic payouts.
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

export const NO_PENDING_PAYOUT = SELECTORS["0x645f76c6"];

function selectorOf(err) {
  for (const d of [err?.data, err?.info?.error?.data, err?.error?.data]) {
    if (typeof d === "string" && /^0x[0-9a-fA-F]{8}/.test(d)) return d.slice(0, 10).toLowerCase();
  }
  return null;
}

export function explain(err) {
  if (err instanceof ActionError) return err.message;
  const sel = selectorOf(err);
  if (sel && SELECTORS[sel]) return SELECTORS[sel];
  if (err?.code === 4001 || err?.code === "ACTION_REJECTED") return "You cancelled the request in your wallet.";
  if (err?.code === "INSUFFICIENT_FUNDS") return "Your wallet does not have enough ETH to pay for this transaction.";
  return `The transaction failed: ${err?.shortMessage || err?.message || String(err)}`;
}

export function explainAmount(err, symbol) {
  if (err?.name === "ScheduleError" && err.code === "empty") return SELECTORS["0x21bb36f6"];
  switch (err?.code) {
    case "empty": return "Enter an amount.";
    case "not_a_number": return "Enter the amount as a number.";
    case "separator": return "Use a period for decimals and no separators, for example 1500.25.";
    case "too_many_decimals": return `Use at most ${err.decimals} decimal places.`;
    case "negative": return "The amount cannot be negative.";
    case "zero": return "The amount must be above zero.";
    case "too_large": return `That is more ${symbol} than a single ENFT can hold.`;
    case "rate_rounds_to_zero": return "This rate is too small to pay anything. Enter a larger rate.";
    case "indefinite_not_last": return SELECTORS["0x8dba7587"];
    case "too_long": return SELECTORS["0x15a7d4e1"];
    case "zero_length": return SELECTORS["0x91378467"];
    case "bad_interval": return SELECTORS["0x5fabb610"];
    default: return String(err?.message || err);
  }
}
