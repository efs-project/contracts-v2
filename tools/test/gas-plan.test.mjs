// SPDX-License-Identifier: MIT
// The planning rule of tools/gas-plan.mjs (design §10.4, gas/model.json `planning` and `profiles.<schedule>.floor`): it
// reads nothing but the model, its quote is the kernel's formula, `tagLists.priceAsNew` is read from the model, it
// refuses past the Realm limits, and test/vectors/floor-plan.json is what it computes from the committed model.
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";
import { planVectors, planner, priceAsNew, shapes } from "../gas-plan.mjs";

const root = join(fileURLToPath(import.meta.url), "../../..");
const committed = () => JSON.parse(readFileSync(join(root, "gas/model.json"), "utf8"));
const freeze = (o) => { if (o && typeof o === "object") { Object.values(o).forEach(freeze); Object.freeze(o); } return o; };
const schedules = (m) => Object.keys(m.profiles);

test("the planner imports nothing but node:assert, so it can use only the model it is given", () => {
  const src = readFileSync(join(root, "tools/gas-plan.mjs"), "utf8");
  const imports = [...src.matchAll(/^import .* from "([^"]+)";$/gm)].map((m) => m[1]);
  assert.deepEqual(imports, ["node:assert/strict"]);
  assert.doesNotMatch(src, /readFileSync|process\.env|fetch\(/);
});

test("every shape plans on every schedule of a frozen model", () => {
  const model = freeze(committed());
  for (const s of schedules(model)) {
    const pl = planner(model, s);
    for (const [name, sh] of Object.entries(shapes(model))) {
      const k = pl.largest(sh.of, Math.floor(model.planning.limits.maxActions / sh.units));
      assert.ok(k >= 1, `${s} ${name}`);
      const c = pl.check(sh.of(k));
      assert.ok(c.fits && Math.max(c.E, c.V) <= c.budget, `${s} ${name}: the largest fits`);
      assert.ok(c.V >= c.E, "V is never below E (the final check needs E + F·64/63 + T)");
    }
  }
});

test("the quote is the kernel's formula (design §10.4) on a hand-computed publication", () => {
  const model = committed();
  for (const s of schedules(model)) {
    const { workModel: w, limits: l, types } = model.profiles[s].floor;
    const acts = [
      { kind: "create" },
      { kind: "publish", shape: "files-child/1 form 0", bytes: 100, fresh: true },
      { kind: "publish", shape: "files-bytes/1", bytes: 64, fresh: false },
      { kind: "bind", cost: "bindHeadFresh", first: true },
      { kind: "bind", cost: "bindHeadRebind", first: false },
    ];
    const t = types["files-child/1"];
    // the existing files-bytes/1 pays freshPerPublishExisting, the HEAD re-bind (a later statement) rwPerBindLater
    const fresh10 = w.freshPerPublication + w.freshPerPublishFresh + w.freshPerDigestSpec * t.specs + w.freshPerRef * t.refs + w.freshPerRef * types["files-bytes/1"].refs + w.freshPerPublishExisting + w.freshPerBindFresh;
    const rw10 = w.rwPerPublication + 2 * w.rwPerPublish + 2 * w.rwPerBind + w.rwPerBindLater;
    const fresh = Math.ceil(fresh10 / 10);
    const rw = Math.ceil(rw10 / 10);
    const q = planner(model, s).quote(acts);
    assert.equal(q.freshSlots, fresh);
    assert.equal(q.rewrites, rw);
    assert.equal(q.prefixFloor, w.computeBase + 5 * w.computePerAction + 2 * w.computePerHookEffect + fresh * l.floorFreshGas + rw * l.floorRewriteGas);
    assert.equal(q.finalReserve, w.finalComputeBase + 2 * w.finalComputePerBind + 2 * w.finalComputePerPublish);
  }
});

test("V adds the two 63/64 steps, the dispatch overhead, the final reserve and the kernel tail", () => {
  const model = committed();
  const f = model.profiles.prague.floor;
  const pl = planner(model, "prague");
  const P = 1_000_000;
  const need = Math.ceil(((Math.ceil((P * 64) / 63) + f.dispatchOverhead) * 64) / 63);
  assert.ok(Math.abs(pl.prefixNeed(P) - need) <= 1);
  const q = { prefixFloor: P, finalReserve: 63_000 };
  assert.equal(pl.visible(0, 5_000_000, q), 5_000_000 + pl.prefixNeed(P) + 64_000 + f.limits.kernelTail);
  assert.equal(pl.visible(9_000_000, 0, q), 9_000_000 + 64_000 + f.limits.kernelTail, "E dominates when the floor is small");
});

test("tagLists.priceAsNew is read from the model", () => {
  const model = committed();
  assert.deepEqual([0, 1, 2, 3, 4, 5, 6, 10].map((n) => priceAsNew(model, n)), [true, true, false, false, false, true, false, true]);
  const other = { ...model, tagLists: { ...model.tagLists, priceAsNew: { entries: [], entriesMultipleOf: 2 } } };
  assert.deepEqual([0, 1, 2, 3].map((n) => priceAsNew(other, n)), [true, false, true, false]);
  const deep = shapes(model).firstTagsDepth8New.of(3).map((a) => Object.keys(a.levels).sort().join());
  assert.deepEqual(deep, ["mineNew,sharedNew", "mineNew,sharedNew", "mineExisting,sharedExisting"]);
});

test("the Realm limits refuse before gas", () => {
  const model = committed();
  const pl = planner(model, "prague");
  const create = { kind: "create" };
  assert.equal(pl.check(Array(model.planning.limits.maxActions + 1).fill(create)).refused, "maxActions");
  assert.equal(pl.check([]).refused, "empty");
  const big = { kind: "publish", shape: "files-bytes/1", bytes: 8192, fresh: true };
  assert.equal(pl.check([big, big, big]).refused, "maxBodyBytesPerPublication");
});

test("test/vectors/floor-plan.json is the rule's verdict on the committed model", () => {
  const model = committed();
  const have = JSON.parse(readFileSync(join(root, "test/vectors/floor-plan.json"), "utf8"));
  assert.deepEqual(have, JSON.parse(JSON.stringify(planVectors(model))));
});
