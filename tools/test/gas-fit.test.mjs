// SPDX-License-Identifier: MIT
// The anchor rule of gas/model.json's fixed term (tools/gas-fit.mjs): a row added to the model never changes the price
// of an existing action, because `fixed` is the median over the anchor pairs only.
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";
import { FIXED_ANCHORS, allGasOverBoundPercent, fixedFrom, overBound } from "../gas-fit.mjs";

const root = join(fileURLToPath(import.meta.url), "../../..");
const committed = () => JSON.parse(readFileSync(join(root, "gas/model.json"), "utf8"));

test("fixed is the median over the anchors of the committed model, on every schedule", () => {
  const model = committed();
  for (const [s, p] of Object.entries(model.profiles)) {
    assert.deepEqual(p.fit.fixedAnchors, [...FIXED_ANCHORS], `${s}: the model records the anchors it was fitted with`);
    // impliedFixedByPair is rounded per pair, so the median of the rounded values is within 1 of the rounded median
    assert.ok(Math.abs(fixedFrom(p.fit.impliedFixedByPair) - p.constants.fixed) <= 1, `${s}: fixed is the anchors' median`);
  }
  assert.ok(Object.keys(model.profiles).length >= 1);
});

test("a pair that is not an anchor never changes fixed", () => {
  const model = committed();
  for (const [s, p] of Object.entries(model.profiles)) {
    const by = p.fit.impliedFixedByPair;
    const others = Object.keys(by).filter((k) => !FIXED_ANCHORS.includes(k));
    assert.ok(others.length >= 13, `${s}: the statement rows are recorded but are not anchors`);
    for (const k of ["bind property fresh", "bind same fresh word", "restore broader"]) assert.ok(others.includes(k), `${s}: ${k} is not an anchor`);
    const base = fixedFrom(by);
    // every non-anchor pair far below, far above, and a thousand more of them: fixed does not move
    for (const v of [-1e9, 0, 1e9]) assert.equal(fixedFrom({ ...by, ...Object.fromEntries(others.map((k) => [k, v])) }), base);
    const many = Object.fromEntries(Array.from({ length: 1000 }, (_, i) => [`new row ${i}`, 0]));
    assert.equal(fixedFrom({ ...by, ...many }), base);
    // an anchor does move it
    const lowered = Object.fromEntries(FIXED_ANCHORS.map((k) => [k, by[k] - 1000]));
    assert.equal(fixedFrom({ ...by, ...lowered }), base - 1000);
  }
});

test("a missing anchor is refused, not silently dropped from the median", () => {
  const by = committed().profiles.prague.fit.impliedFixedByPair;
  const { [FIXED_ANCHORS[0]]: _, ...rest } = by;
  assert.throws(() => fixedFrom(rest), /no anchor pair/);
});

// ---- the stated bound (tools/gas-fit.mjs overBound) ----------------------------------------------------------------

const composite = (key, errorPercent, extra = {}) => ({ key, state: "acrossPlaces", measured: 20_000_000, predicted: Math.round(20_000_000 * (1 + errorPercent / 100)), errorPercent, executionErrorPercent: 0, laterStatements: 32, ...extra });
const profileOf = (name, validation) => ({ [name]: { validation, maximaExcludeStates: ["beyondClaim"], maxUnderErrorPercent: 0, ...(name === "amsterdam" ? { maxUnderExecutionErrorPercent: 0, maxOverExecutionErrorPercent: 0 } : { maxOverErrorPercent: 0 }) } });
const bound = { limitPercent: 15, freshSlotStateGas: 97_920 };

test("amsterdam all-gas over-predictions are bounded per composite by 15% plus its later statements' fresh-slot state gas", () => {
  // 32 later statements × 97,920 over 20,000,000 measured = 15.67 points: the bound is 30.6688%
  assert.equal(allGasOverBoundPercent(composite("x", 0), 15, 97_920).toFixed(2), "30.67");
  assert.deepEqual(overBound(profileOf("amsterdam", [composite("at the edge", 30.66)]), bound), [], "at the edge it passes");
  const out = overBound(profileOf("amsterdam", [composite("over for another reason", 30.68)]), bound);
  assert.equal(out.length, 1, "an over-prediction past the bound is refused");
  assert.match(out[0], /over for another reason.*over its bound 30\.67%/);
  // a composite with no later statements gets no allowance: 15%
  assert.equal(overBound(profileOf("amsterdam", [composite("no later statements", 15.5, { laterStatements: 0 })]), bound).length, 1);
  assert.deepEqual(overBound(profileOf("amsterdam", [composite("beyond", 99, { state: "beyondClaim" })]), bound), [], "beyondClaim is excluded");
});

test("under-predictions are bounded everywhere, over-predictions on the gas the cap counts", () => {
  assert.equal(overBound(profileOf("amsterdam", [composite("under all gas", -15.5)]), bound).length, 1, "amsterdam all-gas under-prediction");
  assert.equal(overBound(profileOf("amsterdam", [composite("over execution", 1, { executionErrorPercent: 15.5 })]), bound).length, 1, "amsterdam execution over-prediction");
  assert.equal(overBound(profileOf("amsterdam", [composite("under execution", 1, { executionErrorPercent: -15.5 })]), bound).length, 1, "amsterdam execution under-prediction");
  assert.equal(overBound(profileOf("prague", [composite("prague over", 15.5, { executionErrorPercent: undefined })]), bound).length, 1, "prague all-gas over-prediction (the cap counts all gas)");
  assert.equal(overBound(profileOf("prague", [composite("prague under", -15.5, { executionErrorPercent: undefined })]), bound).length, 1, "prague all-gas under-prediction");
  assert.deepEqual(overBound(profileOf("prague", [composite("prague inside", 14.9, { executionErrorPercent: undefined })]), bound), []);
  // a stated maximum over the limit is refused as well
  assert.equal(overBound({ amsterdam: { validation: [], maximaExcludeStates: [], maxUnderErrorPercent: 15.1 } }, bound).length, 1);
});
