import test from "node:test";
import assert from "node:assert/strict";
import {
  U64_MAX, parseAmount, parseFee, formatAmount, durationSeconds, ratePerSecond, effectiveRate,
  toSegments, scheduleTotal, amountWarning, MAX_PERIODS,
  percentToWeight, baseUnit, toWeightSegments, effectiveSegments, unitPerDay,
} from "../js/units.js";

test("parseAmount", () => {
  assert.equal(parseAmount("1000.5", 6), 1000500000n);
  assert.equal(parseAmount("0.000001", 6), 1n);
  assert.throws(() => parseAmount("0.0000001", 6), { code: "too_many_decimals" });
  assert.throws(() => parseAmount("", 6), { code: "empty" });
  assert.throws(() => parseAmount("abc", 6), { code: "not_a_number" });
  assert.throws(() => parseAmount("0", 6), { code: "zero" });
  assert.throws(() => parseAmount("-1", 6), { code: "negative" });
  assert.throws(() => parseAmount("18446744073710", 6), { code: "too_large" });
});

test("formatAmount", () => {
  assert.equal(formatAmount(1000500000n, 6), "1,000.5");
  assert.equal(formatAmount(1000500000n, 6, {grouping: false}), "1000.5");
  assert.equal(formatAmount(1234567890000000n, 6, {grouping: false}), "1234567890");
  assert.equal(formatAmount(1n, 6), "0.000001");
  assert.equal(formatAmount(2000000n, 6), "2");
  assert.equal(formatAmount(0n, 6), "0");
});

test("durationSeconds", () => {
  assert.equal(durationSeconds(2, "days"), 172800n);
  assert.equal(durationSeconds(1, "weeks"), 604800n);
  assert.equal(durationSeconds(1, "months"), 2592000n);
  assert.equal(durationSeconds(1, "years"), 31536000n);
});

test("ratePerSecond", () => {
  assert.equal(ratePerSecond("100", "day", 6), 1157n);
  assert.equal(effectiveRate(1157n, "day", 6), "99.9648");
  assert.equal(effectiveRate(1157000n, "day", 6), "99,964.8");
  assert.equal(effectiveRate(1157000n, "day", 6, {grouping: false}), "99964.8");
  assert.throws(() => ratePerSecond("1", "month", 6), { code: "rate_rounds_to_zero" });
  assert.equal(ratePerSecond("0.0001", "day", 9), 1n);
});

test("toSegments marks the indefinite tail", () => {
  const s = toSegments([
    { length: 18, unit: "months", rate: "100", per: "day" },
    { rate: "25", per: "day", indefinite: true },
  ], 6);
  assert.equal(s[0].duration, 46656000n);
  assert.equal(s[0].ratePerSec, 1157n);
  assert.equal(s[1].duration, U64_MAX);
  assert.equal(s[1].ratePerSec, 289n);
});

test("toSegments rejects an indefinite row that is not last", () => {
  assert.throws(() => toSegments([
    { rate: "25", per: "day", indefinite: true },
    { length: 1, unit: "days", rate: "1", per: "day" },
  ], 6), { code: "indefinite_not_last" });
});

test("toSegments rejects empty and zero-length", () => {
  assert.throws(() => toSegments([], 6), { code: "empty" });
  assert.throws(() => toSegments([{ length: 0, unit: "days", rate: "1", per: "day" }], 6), { code: "zero_length" });
});

test("scheduleTotal", () => {
  assert.equal(scheduleTotal([{ duration: 100n, ratePerSec: 2n }, { duration: 100n, ratePerSec: 5n }]), 700n);
  assert.equal(scheduleTotal([{ duration: 100n, ratePerSec: 2n }, { duration: U64_MAX, ratePerSec: 5n }]), null);
});

const fixed = [{ duration: 100n, ratePerSec: 2n }, { duration: 100n, ratePerSec: 5n }];

test("amountWarning: stops early", () => {
  assert.deepEqual(amountWarning(fixed, 1000n, 300n), { kind: "stops_early", at: 1120n });
});
test("amountWarning: leftover", () => {
  assert.deepEqual(amountWarning(fixed, 1000n, 1000n), { kind: "leftover", extra: 300n });
});
test("amountWarning: exact", () => {
  assert.equal(amountWarning(fixed, 1000n, 700n), null);
});
test("amountWarning: indefinite runs dry", () => {
  const s = [{ duration: 100n, ratePerSec: 2n }, { duration: U64_MAX, ratePerSec: 3n }];
  assert.deepEqual(amountWarning(s, 1000n, 500n), { kind: "runs_dry", at: 1200n });
});

test("parseAmount accepts digits and at most one period, and refuses any separator", () => {
  assert.equal(parseAmount("1500.25", 6), 1500250000n);
  assert.equal(parseAmount("1000000", 6), 1000000000000n);
  assert.equal(parseAmount(".5", 6), 500000n);
  assert.equal(parseAmount("  1500  ", 6), 1500000000n);
  for (const bad of [
    "1,500", "0,500", "1 500", "1'500", "1.500,25", "1,000.5", "1,000,000", "1,5", "1.000.000",
    "1_500", "1\u00a0500", "1\u2009500", "1\u2019500", "-1,5",
  ]) {
    assert.throws(() => parseAmount(bad, 6), { name: "AmountError", code: "separator" }, bad);
  }
  for (const bad of ["abc", "1e5", "0x10", "1500 MOCK", "$1500", "."]) {
    assert.throws(() => parseAmount(bad, 6), { code: "not_a_number" }, bad);
  }
});

test("toSegments bounds fixed lengths", () => {
  const row = (length, unit = "days") => [{ length, unit, rate: "1", per: "day" }];
  for (const bad of [-1, "-1", 1.5, "1.5", "abc", "", undefined, 0]) {
    assert.throws(() => toSegments(row(bad), 6), { code: "zero_length" }, String(bad));
  }
  assert.throws(() => toSegments(row("999999999999999999999"), 6), { code: "too_long" });
  assert.throws(() => toSegments(row(1e30), 6), { code: "too_long" });
  const half = "106751991167301"; // days; each is below U64_MAX, two together are above
  assert.equal(toSegments(row(half), 6).length, 1);
  assert.throws(() => toSegments([...row(half), ...row(half)], 6), { code: "too_long" });
  assert.throws(() => toSegments([...row(half), ...row(half), { rate: "1", per: "day", indefinite: true }], 6), { code: "too_long" });
});

test("intervalSeconds: a whole number of hours, days or weeks between 1 hour and 365 days", async () => {
  const {intervalSeconds, INTERVAL_UNITS} = await import("../js/units.js");
  assert.deepEqual(INTERVAL_UNITS, {hours: 3600, days: 86400, weeks: 604800});
  assert.equal(intervalSeconds("1", "days"), 86400);
  assert.equal(intervalSeconds("1", "hours"), 3600);
  assert.equal(intervalSeconds("365", "days"), 31536000);
  assert.equal(intervalSeconds(" 2 ", "weeks"), 1209600);
  for (const [value, unit] of [["0", "hours"], ["1.5", "days"], ["366", "days"], ["", "days"], ["-1", "days"], ["abc", "hours"], ["53", "weeks"]]) {
    assert.throws(() => intervalSeconds(value, unit), {name: "ScheduleError", code: "bad_interval"}, `${value} ${unit}`);
  }
});

test("intervalText names the largest unit that divides evenly", async () => {
  const {intervalText} = await import("../js/units.js");
  assert.equal(intervalText(86400), "1 day");
  assert.equal(intervalText(129600), "36 hours");
  assert.equal(intervalText(1209600), "2 weeks");
  assert.equal(intervalText(604800), "1 week");
  assert.equal(intervalText(3600), "1 hour");
  assert.equal(intervalText(172800), "2 days");
  assert.equal(intervalText(5400), "90 minutes");
});

test("parseFee reads ETH as wei, with zero and empty meaning no fee", () => {
  assert.equal(parseFee("0.001"), 1_000_000_000_000_000n);
  assert.equal(parseFee("1"), 1_000_000_000_000_000_000n);
  assert.equal(parseFee("0"), 0n);
  assert.equal(parseFee("0.0"), 0n);
  assert.equal(parseFee(""), 0n);
  assert.equal(parseFee("  "), 0n);
  assert.throws(() => parseFee("1,5"), {code: "separator"});
  assert.throws(() => parseFee("abc"), {code: "not_a_number"});
  assert.throws(() => parseFee("-1"), {code: "negative"});
  assert.throws(() => parseFee("0.0000000000000000001"), {code: "too_many_decimals"});
  assert.throws(() => parseFee("19"), {code: "too_large"});
});

test("toSegments allows 256 periods and rejects more", () => {
  const rows = n => Array.from({ length: n }, () => ({ length: 1, unit: "days", rate: "1", per: "day" }));
  assert.equal(MAX_PERIODS, 256);
  assert.equal(toSegments(rows(256), 6).length, 256);
  assert.equal(toSegments([...rows(255), { rate: "1", per: "day", indefinite: true }], 6).length, 256);
  assert.throws(() => toSegments(rows(257), 6), { code: "too_many" });
});

test("percentToWeight", () => {
  assert.equal(percentToWeight("100"), 1000n);
  assert.equal(percentToWeight("12.5"), 125n);
  assert.equal(percentToWeight("0"), 0n);
  assert.equal(percentToWeight(" 250 "), 2500n);
  assert.equal(percentToWeight("429496729.5"), 4294967295n);
  for (const bad of ["12.55", "-1", "", "abc", "1e3", "429496729.6"]) {
    assert.throws(() => percentToWeight(bad), { name: "ScheduleError", code: "bad_percent" }, bad);
  }
});

test("baseUnit", () => {
  assert.equal(baseUnit("1", "day", 9), 49710269629n);
  assert.equal(baseUnit("0.5", "month", 9), 828504493n);
  assert.throws(() => baseUnit("0.000000001", "year", 9), { name: "AmountError", code: "rate_rounds_to_zero" });
  assert.throws(() => baseUnit("18446744073709551615", "day", 0), { name: "AmountError", code: "too_large" });
});

test("unitPerDay", () => {
  assert.equal(unitPerDay(49710269629n, 9), "0.999999999");
  assert.equal(unitPerDay(1n << 32n, 0), "86,400,000");
});

test("toWeightSegments", () => {
  assert.deepEqual(
    toWeightSegments([{ length: "100", unit: "days", percent: "100" }, { indefinite: true, percent: "50" }]),
    [{ duration: 8640000n, ratePerSec: 1000n }, { duration: U64_MAX, ratePerSec: 500n }],
  );
  assert.throws(() => toWeightSegments([{ indefinite: true, percent: "0" }]), { code: "zero_percent_indefinite" });
  const many = Array.from({ length: MAX_PERIODS + 1 }, () => ({ length: "1", unit: "days", percent: "1" }));
  assert.throws(() => toWeightSegments(many), { code: "too_many" });
  assert.throws(() => toWeightSegments([]), { code: "empty" });
});

test("effectiveSegments", () => {
  assert.equal(effectiveSegments([{ duration: 100n, ratePerSec: 1000n }], 49710269629n)[0].ratePerSec, 11574n);
  assert.equal(effectiveSegments([{ duration: 100n, ratePerSec: 1000n }], 49710269629n)[0].duration, 100n);
});
