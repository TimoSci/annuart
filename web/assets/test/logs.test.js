import test from "node:test";
import assert from "node:assert/strict";
import {recentLogs, LOG_LOOKBACK, LOG_CHUNK} from "../js/chain/logs.js";

// A contract whose queryFilter is recorded; `failOn(call)` makes a call throw.
function fakeContract(head, {failOn = () => false} = {}) {
  const calls = [];
  return {
    calls,
    runner: {provider: {getBlockNumber: async () => head}},
    async queryFilter(filter, from, to) {
      calls.push([from, to]);
      if (failOn(calls.length)) throw new Error("query returned more than 10000 results");
      return [{blockNumber: from}, {blockNumber: to}];
    },
  };
}

test("the constants", () => {
  assert.equal(LOG_LOOKBACK, 50_000);
  assert.equal(LOG_CHUNK, 2_000);
});

test("reads the look-back window in one call", async () => {
  const c = fakeContract(1_000_000);
  await recentLogs(c, "f", 10);
  assert.deepEqual(c.calls, [[950_000, 1_000_000]]);
});

test("does not read before the deployment", async () => {
  const c = fakeContract(3_000);
  await recentLogs(c, "f", 2_500);
  assert.deepEqual(c.calls, [[2_500, 3_000]]);
});

test("a refused query is repeated in slices that neither overlap nor leave a gap", async () => {
  const c = fakeContract(1_000_000, {failOn: n => n === 1});
  const logs = await recentLogs(c, "f", 10);
  const slices = c.calls.slice(1);
  assert.equal(slices[0][0], 950_000);
  assert.equal(slices.at(-1)[1], 1_000_000);
  slices.forEach(([from, to], i) => {
    assert.ok(to - from + 1 <= LOG_CHUNK);
    if (i > 0) assert.equal(from, slices[i - 1][1] + 1);
  });
  assert.equal(slices.length, 26);
  assert.deepEqual(logs.map(l => l.blockNumber), slices.flat());
  assert.deepEqual(logs.map(l => l.blockNumber), [...logs.map(l => l.blockNumber)].sort((a, b) => a - b));
});

test("a slice that is refused fails the read", async () => {
  const c = fakeContract(1_000_000, {failOn: n => n === 1 || n === 4});
  await assert.rejects(recentLogs(c, "f", 10), /more than 10000 results/);
});
