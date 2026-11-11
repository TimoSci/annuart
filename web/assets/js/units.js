// Amount, rate and schedule maths. bigint throughout; no floating point.

export const U64_MAX = 18446744073709551615n;

export class AmountError extends Error {
  constructor(code, decimals) {
    super(code);
    this.name = "AmountError";
    this.code = code;
    this.decimals = decimals;
  }
}

export class ScheduleError extends Error {
  constructor(code) {
    super(code);
    this.name = "ScheduleError";
    this.code = code;
  }
}

const UNIT_SECONDS = { days: 86400n, weeks: 604800n, months: 2592000n, years: 31536000n };
const PER_SECONDS = { day: 86400n, month: 2592000n, year: 31536000n };

export function parseAmount(text, decimals) {
  const trimmed = String(text ?? "").trim();
  if (trimmed === "") throw new AmountError("empty", decimals);
  // A comma is a thousands separator only: integer part, groups of exactly three.
  const intPart = trimmed.split(".")[0];
  if (intPart.includes(",") && !/^-?\d{1,3}(,\d{3})+$/.test(intPart)) {
    throw new AmountError("not_a_number", decimals);
  }
  if (trimmed.split(".").slice(1).join(".").includes(",")) throw new AmountError("not_a_number", decimals);
  const raw = trimmed.replace(/,/g, "");
  const m = /^(-)?(\d*)(?:\.(\d*))?$/.exec(raw);
  if (!m || (m[2] === "" && (m[3] ?? "") === "")) throw new AmountError("not_a_number", decimals);
  const [, neg, whole, frac = ""] = m;
  if (frac.length > decimals) {
    // Extra digits are fine only if they are all zeros.
    if (/[1-9]/.test(frac.slice(decimals))) throw new AmountError("too_many_decimals", decimals);
  }
  const units = BigInt((whole || "0") + frac.slice(0, decimals).padEnd(decimals, "0"));
  if (units === 0n) throw new AmountError("zero", decimals);
  if (neg) throw new AmountError("negative", decimals);
  if (units > U64_MAX) throw new AmountError("too_large", decimals);
  return units;
}

export function formatAmount(units, decimals) {
  const base = 10n ** BigInt(decimals);
  const whole = (units / base).toString().replace(/\B(?=(\d{3})+(?!\d))/g, ",");
  const frac = (units % base).toString().padStart(decimals, "0").replace(/0+$/, "");
  return frac ? `${whole}.${frac}` : whole;
}

export function durationSeconds(n, unit) {
  const s = UNIT_SECONDS[unit];
  if (s === undefined) throw new RangeError(`unknown unit ${unit}`);
  return BigInt(n) * s;
}

function perSeconds(per) {
  const s = PER_SECONDS[per];
  if (s === undefined) throw new RangeError(`unknown period ${per}`);
  return s;
}

export function ratePerSecond(amountText, per, decimals) {
  const rate = parseAmount(amountText, decimals) / perSeconds(per);
  if (rate === 0n) throw new AmountError("rate_rounds_to_zero", decimals);
  return rate;
}

export function effectiveRate(perSec, per, decimals) {
  return formatAmount(perSec * perSeconds(per), decimals);
}

export function toSegments(rows, decimals) {
  if (!rows || rows.length === 0) throw new ScheduleError("empty");
  let fixedTotal = 0n;
  const segments = rows.map((row, i) => {
    let duration;
    if (row.indefinite) {
      if (i !== rows.length - 1) throw new ScheduleError("indefinite_not_last");
      duration = U64_MAX;
    } else {
      duration = fixedDuration(row.length, row.unit);
      fixedTotal += duration;
      if (fixedTotal >= U64_MAX) throw new ScheduleError("too_long");
    }
    return { duration, ratePerSec: ratePerSecond(row.rate, row.per, decimals) };
  });
  return segments;
}

// A whole, positive number of units, with duration below U64_MAX.
function fixedDuration(length, unit) {
  let n;
  if (typeof length === "number" && Number.isInteger(length)) n = BigInt(length);
  else if (typeof length === "string" && /^\d+$/.test(length.trim())) n = BigInt(length.trim());
  else throw new ScheduleError("zero_length");
  if (n <= 0n) throw new ScheduleError("zero_length");
  const duration = durationSeconds(n, unit);
  if (duration >= U64_MAX) throw new ScheduleError("too_long");
  return duration;
}

const isIndefinite = (segments) => segments.some((s) => s.duration === U64_MAX);

export function scheduleTotal(segments) {
  if (isIndefinite(segments)) return null;
  return segments.reduce((sum, s) => sum + s.duration * s.ratePerSec, 0n);
}

// Unix time at which cumulative payout reaches `amount`, rounded up to a whole
// second; null if a fixed schedule pays less than `amount` in total.
export function runsDryAt(segments, start, amount) {
  let remaining = amount;
  let t = start;
  for (const s of segments) {
    if (s.ratePerSec === 0n) {
      if (s.duration === U64_MAX) return null;
      t += s.duration;
      continue;
    }
    const pay = s.duration * s.ratePerSec;
    if (pay >= remaining) {
      return t + (remaining + s.ratePerSec - 1n) / s.ratePerSec;
    }
    remaining -= pay;
    t += s.duration;
  }
  return null;
}

export function amountWarning(segments, start, amount) {
  const total = scheduleTotal(segments);
  if (total === null) return { kind: "runs_dry", at: runsDryAt(segments, start, amount) };
  if (total > amount) return { kind: "stops_early", at: runsDryAt(segments, start, amount) };
  if (total < amount) return { kind: "leftover", extra: amount - total };
  return null;
}
