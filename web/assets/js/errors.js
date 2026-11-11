// Turns wallet and contract failures into plain sentences.

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
};

function selectorOf(err) {
  for (const d of [err?.data, err?.info?.error?.data, err?.error?.data]) {
    if (typeof d === "string" && /^0x[0-9a-fA-F]{8}/.test(d)) return d.slice(0, 10).toLowerCase();
  }
  return null;
}

export function explain(err) {
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
    case "too_many_decimals": return `Use at most ${err.decimals} decimal places.`;
    case "negative": return "The amount cannot be negative.";
    case "zero": return "The amount must be above zero.";
    case "too_large": return `That is more ${symbol} than a single ENFT can hold.`;
    case "rate_rounds_to_zero": return "This rate is too small to pay anything. Enter a larger rate.";
    case "indefinite_not_last": return SELECTORS["0x8dba7587"];
    case "zero_length": return SELECTORS["0x91378467"];
    default: return String(err?.message || err);
  }
}
