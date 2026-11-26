// SPDX-License-Identifier: MIT
// One table of storage prices per fee schedule (tools/deploy-plan.mjs GAS_SCHEDULES): the floor prices every tool
// uses are read from it, its Solidity mirror (test/vectors/gas-schedules.json, which test/integration/FloorPrices.t.sol
// checks KernelDeploy.s1Limits() against and measures) equals it, and docs/GAS-SCHEDULES.md's table states it. Nobody
// can change one copy without this failing.
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";
import { GAS_SCHEDULES, GLAMSTERDAM_FLOOR, LIMITS, floorPrices } from "../deploy-plan.mjs";

const root = join(fileURLToPath(import.meta.url), "../../..");
const read = (p) => readFileSync(join(root, p), "utf8");

test("the floor prices of both schedules are the table's fresh and cold-rewrite execution gas", () => {
  for (const [s, l] of [["prague", LIMITS], ["amsterdam", GLAMSTERDAM_FLOOR]]) {
    assert.equal(l.floorFreshGas, GAS_SCHEDULES[s].freshSlot.executionGas, `${s} floorFreshGas`);
    assert.equal(l.floorRewriteGas, GAS_SCHEDULES[s].rewriteColdSlot.executionGas, `${s} floorRewriteGas`);
    assert.deepEqual(floorPrices(s), { floorFreshGas: l.floorFreshGas, floorRewriteGas: l.floorRewriteGas });
  }
  // the kernel tail is compute, not a schedule price: the same on both
  assert.equal(GLAMSTERDAM_FLOOR.kernelTail, LIMITS.kernelTail);
  // EIP-8038: on Glamsterdam a cold rewrite costs the execution gas of a fresh slot
  assert.equal(GAS_SCHEDULES.amsterdam.rewriteColdSlot.executionGas, GAS_SCHEDULES.amsterdam.freshSlot.executionGas);
});

test("test/vectors/gas-schedules.json mirrors the table exactly", () => {
  const mirror = JSON.parse(read("test/vectors/gas-schedules.json"));
  assert.equal(mirror.schema, "efs/vectors/gas-schedules/1");
  assert.deepEqual(mirror.schedules, GAS_SCHEDULES);
});

/** The numbers in a markdown cell ("≈ 110,020 (97,920 state gas + 12,100)" → [110020, 97920, 12100]). */
const numbers = (cell) => [...cell.matchAll(/\d[\d,]*/g)].map((m) => Number(m[0].replaceAll(",", "")));

test("docs/GAS-SCHEDULES.md's table states the table", () => {
  const rows = read("docs/GAS-SCHEDULES.md").split("\n").filter((l) => l.startsWith("|"));
  const row = (prefix) => {
    const r = rows.find((l) => l.startsWith(`| ${prefix}`));
    assert.ok(r, `no row "${prefix}" in docs/GAS-SCHEDULES.md`);
    return r.split("|").slice(1, -1).map((c) => c.trim());
  };
  const header = row("Schedule");
  assert.deepEqual(header.slice(2), ["Fresh storage slot", "Rewrite of an existing slot (cold)", "Code deposit", "New account"]);
  const p = row("Prague/Osaka");
  const g = GAS_SCHEDULES.prague;
  assert.deepEqual(numbers(p[2]), [g.freshSlot.executionGas]);
  assert.deepEqual(numbers(p[3]), [g.rewriteColdSlot.executionGas]);
  assert.deepEqual(numbers(p[4]), [g.codeDepositPerByte.executionGas]);
  assert.deepEqual(numbers(p[5]), [g.newAccount.executionGas]);
  const a = row("Glamsterdam");
  const h = GAS_SCHEDULES.amsterdam;
  assert.deepEqual(numbers(a[2]), [h.freshSlot.stateGas + h.freshSlot.executionGas, h.freshSlot.stateGas, h.freshSlot.executionGas]);
  assert.deepEqual(numbers(a[3]), [h.rewriteColdSlot.executionGas]);
  assert.deepEqual(numbers(a[4]), [h.codeDepositPerByte.stateGas]);
  assert.deepEqual(numbers(a[5]), [h.newAccount.stateGas]);
});

test("the gas model's floor limits are the table's prices on each schedule", () => {
  const src = read("tools/gas-model.mjs");
  // gas-model.mjs takes the floor limits from LIMITS and GLAMSTERDAM_FLOOR, never from literals
  assert.match(src, /amsterdam: GLAMSTERDAM_FLOOR/);
  assert.doesNotMatch(src, /floorRewriteGas: \d/);
  assert.doesNotMatch(src, /floorFreshGas: \d/);
});
