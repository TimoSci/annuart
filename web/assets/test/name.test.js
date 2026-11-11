import test from "node:test";
import assert from "node:assert/strict";
import {decodeBytes32String, ZeroHash} from "ethers";
import {NAME_MAX, nameProblem, nameToBytes32} from "../js/name.js";

test("no name is the zero word", () => {
  assert.equal(nameProblem(""), null);
  assert.equal(nameToBytes32(""), ZeroHash);
});

test("an allowed name round-trips through bytes32", () => {
  for (const name of ["Ada's fund_no.2 - A", "x", "a".repeat(NAME_MAX)]) {
    assert.equal(nameProblem(name), null);
    assert.equal(decodeBytes32String(nameToBytes32(name)), name);
  }
});

test("anything the contract refuses is refused here first", () => {
  for (const name of ["<b>", "a/b", "a\nb", "café", "a‮b", "a\0b", "a".repeat(NAME_MAX + 1)]) {
    assert.notEqual(nameProblem(name), null, JSON.stringify(name));
    assert.throws(() => nameToBytes32(name), undefined, JSON.stringify(name));
  }
  // The form trims; an untrimmed name is never encoded.
  assert.throws(() => nameToBytes32(" lead"));
  assert.throws(() => nameToBytes32("trail "));
});
