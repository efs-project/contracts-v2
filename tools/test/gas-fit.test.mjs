// SPDX-License-Identifier: MIT
// The anchor rule of gas/model.json's fixed term (tools/gas-fit.mjs): a row added to the model never changes the price
// of an existing action, because `fixed` is the median over the anchor pairs only.
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";
import { FIXED_ANCHORS, fixedFrom } from "../gas-fit.mjs";

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
