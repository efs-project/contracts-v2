// SPDX-License-Identifier: MIT
// The planning rule of tools/gas-plan.mjs (design §10.4, gas/model.json `planning` and `profiles.<schedule>.floor`): it
// reads nothing but the model, its quote is the kernel's formula, `tagLists.priceAsNew` is read from the model, it
// refuses past the Realm limits, and test/vectors/floor-plan.json is what it computes from the committed model.
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";
import { PURPOSE, historyWordAdds, isRebind, laterKey, opensHistoryWord, planVectors, planner, priceAsNew, purposeOf, shapes } from "../gas-plan.mjs";
import { PURPOSE as PLAN_PURPOSE, WORK_MODEL } from "../deploy-plan.mjs";

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
  const model = freeze(formula3());
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

/** The committed model with the deploy plan's work model (formula 3) on every schedule: until the release is
 *  regenerated the committed gas/model.json may carry an older formula, and these tests check the planner's formula,
 *  not the committed numbers. */
const formula3 = () => {
  const m = committed();
  for (const p of Object.values(m.profiles)) p.floor.workModel = { ...WORK_MODEL };
  return m;
};
const ZERO = `0x${"0".repeat(64)}`;
/** The surcharge fields of a work model, all zero (no purpose surcharged). */
const NO_SURCHARGE = {
  surchargePurpose: ZERO, surchargeFreshFirst: 0, surchargeRwFirst: 0, surchargeComputeFirst: 0,
  surchargeFreshRebind: 0, surchargeRwRebind: 0, surchargeComputeRebind: 0,
  surchargeFreshLater: 0, surchargeRwLater: 0, surchargeComputeLater: 0,
};
/** `formula3()` with the surcharge cleared. */
const withoutSurcharge = () => {
  const m = formula3();
  for (const p of Object.values(m.profiles)) Object.assign(p.floor.workModel, NO_SURCHARGE);
  return m;
};

test("the planner's purpose words are the deploy plan's", () => {
  assert.deepEqual(PURPOSE, PLAN_PURPOSE);
  assert.equal(purposeOf({ cost: "bindHeadRebind" }), PURPOSE.HEAD);
  assert.equal(purposeOf({ cost: "releaseFolder" }), PURPOSE.FOLDER);
  assert.equal(purposeOf({ cost: "unbindTagLone" }), PURPOSE.TAG);
  assert.equal(purposeOf({ cost: "bindTagFresh", purpose: PURPOSE.SAME }), PURPOSE.SAME, "an explicit purpose wins");
  assert.deepEqual(["bindHeadRebind", "bindFolderRebind", "bindTagNumberChange", "bindPropertyRebind"].map((cost) => isRebind({ cost })), [true, true, true, true]);
  assert.deepEqual(["unbindTag", "releaseFolder", "restoreTag", "restoreSame"].map((cost) => isRebind({ cost })), [false, false, false, false]);
});

test("the planner refuses a work model of another formula", () => {
  const m = formula3();
  m.profiles.prague.floor.workModel.formulaVersion = 2;
  assert.throws(() => planner(m, "prague"), /formula 3/);
});

test("the quote is the kernel's formula (design §10.4, formula 3) on a hand-computed publication", () => {
  const model = formula3();
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
    // the existing files-bytes/1 pays freshPerPublishExisting; the first HEAD statement the first row, the HEAD
    // re-bind the re-bind row
    // both HEAD statements also pay generation 1's HEAD surcharge (the all-authors list) of their class
    assert.equal(w.surchargePurpose, PURPOSE.HEAD, "generation 1 surcharges HEAD");
    const fresh10 = w.freshPerPublication + w.freshPerPublishFresh + w.freshPerDigestSpec * t.specs + w.freshPerRef * t.refs + w.freshPerRef * types["files-bytes/1"].refs + w.freshPerPublishExisting + w.freshPerBindFirst + w.freshPerRebind + w.surchargeFreshFirst + w.surchargeFreshRebind;
    const rw10 = w.rwPerPublication + 2 * w.rwPerPublish + w.rwPerBindFirst + w.rwPerRebind + w.surchargeRwFirst + w.surchargeRwRebind;
    const fresh = Math.ceil(fresh10 / 10);
    const rw = Math.ceil(rw10 / 10);
    const q = planner(model, s).quote(acts);
    assert.equal(q.freshSlots, fresh);
    assert.equal(q.rewrites, rw);
    assert.equal(q.prefixFloor, w.computeBase + 5 * w.computePerAction + w.computePerBindFirst + w.computePerRebind + w.surchargeComputeFirst + w.surchargeComputeRebind + fresh * l.floorFreshGas + rw * l.floorRewriteGas);
    assert.equal(q.finalReserve, w.finalComputeBase + 2 * w.finalComputePerBind + 2 * w.finalComputePerPublish);
  }
});

test("the surcharge charges its purpose only, and every WITHDRAW after the first pays the later row", () => {
  const model = withoutSurcharge();
  for (const s of schedules(model)) {
    const w = model.profiles[s].floor.workModel;
    const plain = planner(model, s);
    const tag = [{ kind: "bind", cost: "unbindTagLone", first: true }, { kind: "bind", cost: "unbindTag", first: false }];
    const head = [{ kind: "bind", cost: "bindHeadFresh", first: true }, { kind: "bind", cost: "bindHeadRebind", first: false }];
    const m = withoutSurcharge();
    Object.assign(m.profiles[s].floor.workModel, {
      surchargePurpose: PURPOSE.HEAD, surchargeFreshFirst: 10, surchargeRwFirst: 10, surchargeComputeFirst: 4500,
      surchargeFreshRebind: 0, surchargeRwRebind: 0, surchargeComputeRebind: 0,
      surchargeFreshLater: 0, surchargeRwLater: 10, surchargeComputeLater: 10_000,
    });
    const sur = planner(m, s);
    assert.deepEqual(sur.quote(tag), plain.quote(tag), `${s}: TAG statements pay nothing for a HEAD surcharge`);
    const a = plain.quote(head);
    const b = sur.quote(head);
    assert.equal(b.freshSlots - a.freshSlots, 1);
    assert.equal(b.rewrites - a.rewrites, 1, "the re-bind's surcharge share is zero");
    const l = model.profiles[s].floor.limits;
    assert.equal(b.prefixFloor - a.prefixFloor, l.floorFreshGas + l.floorRewriteGas + 4500);
    const mask = [{ kind: "bind", cost: "unbindTag", first: false, purpose: PURPOSE.HEAD }];
    assert.equal(sur.quote(mask).prefixFloor - plain.quote(mask).prefixFloor, l.floorRewriteGas + 10_000, `${s}: a HEAD mask pays the later share`);
    // withdraws: the first pays computePerAction only, every later one the later row
    const one = plain.quote([{ kind: "withdraw" }]);
    const two = plain.quote([{ kind: "withdraw" }, { kind: "withdraw" }]);
    assert.equal(two.prefixFloor - one.prefixFloor, w.computePerAction + w.computePerBindLater
      + (two.freshSlots - one.freshSlots) * l.floorFreshGas + (two.rewrites - one.rewrites) * l.floorRewriteGas);
  }
});

test("the surcharge applies on plain equality with surchargePurpose, zero included, as the kernel compares them", () => {
  // LedgerIngress._foldOne: `a.purpose == bytes32(_w(wm, W_SURCHARGE_PURPOSE))`, no special case for zero. A statement's
  // purpose is never zero (the kernel refuses it, E_SHAPE(leaf, 1): test/unit/kernel/Shape.t.sol
  // test_missing_required_field_is_E_SHAPE_1_for_every_kind, for a BIND, an UNBIND and a RELEASE), so a zero
  // surchargePurpose surcharges nothing that can be admitted; the planner still compares exactly as the kernel does.
  for (const s of schedules(withoutSurcharge())) {
    const m = withoutSurcharge();
    Object.assign(m.profiles[s].floor.workModel, { surchargeFreshFirst: 10, surchargeRwFirst: 10, surchargeComputeFirst: 7_000 });
    const pl = planner(m, s);
    const plain = planner(withoutSurcharge(), s);
    const zero = [{ kind: "bind", cost: "bindTagFresh", first: true, purpose: ZERO }];
    const tag = [{ kind: "bind", cost: "bindTagFresh", first: true }];
    const l = m.profiles[s].floor.limits;
    assert.equal(pl.quote(zero).prefixFloor - plain.quote(zero).prefixFloor, l.floorFreshGas + l.floorRewriteGas + 7_000, `${s}: a zero purpose equals a zero surchargePurpose`);
    assert.deepEqual(pl.quote(tag), plain.quote(tag), `${s}: a real purpose never equals a zero surchargePurpose`);
  }
});

test("V adds the two 63/64 steps, the dispatch overhead, the final reserve and the kernel tail", () => {
  const model = formula3();
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

/** The statements about topics (design §12.5) and the model rows they are priced by (tools/gas-model.mjs ACTIONS). */
const STATEMENTS = {
  bindPropertyFresh: true, bindPropertyRebind: false, unbindProperty: false, releaseProperty: false,
  bindSameFreshWord: true, bindSameFreshPath: true, unbindSame: false, releaseSame: false, restoreSame: false,
  bindBroaderFresh: true, unbindBroader: false, releaseBroader: false, restoreBroader: false,
};

test("labels, SAME and BROADER statements are priced from the model alone, on every schedule", () => {
  const model = freeze(formula3());
  for (const s of schedules(model)) {
    const p = model.profiles[s];
    const exec = s === "prague" ? p.constants : p.split.executionGas;
    const pl = planner(model, s);
    for (const [cost, first] of Object.entries(STATEMENTS)) {
      for (const c of [p.constants, exec, p.floor.kernel]) assert.ok(Number.isInteger(c[cost]), `${s}: ${cost}`);
      // a later statement in a short list (the list tiers: these rows are measured at distinct subjects, so they are
      // their own new-place rows)
      const one = pl.check([{ kind: "bind", cost, first, ...(first ? {} : { firstAtPlace: true, entries: 1 }) }]);
      assert.ok(one.fits, `${s} ${cost}`);
      assert.equal(one.E, exec.fixed + exec[cost]);
      assert.equal(one.K, p.floor.kernel.fixed + p.floor.kernel[cost]);
    }
    // a label with its text (EfsTopics.label) composes the text/1 publish row and the first PROPERTY statement
    const label = [{ kind: "publish", shape: "text/1", bytes: 24, fresh: true }, { kind: "bind", cost: "bindPropertyFresh", first: true }];
    const c = pl.check(label);
    assert.equal(c.E, Math.round(exec.fixed + exec.publishNew["text/1"] + exec.perWord + exec.perByte * 24 + exec.bindPropertyFresh));
    const v = p.validation.find((x) => x.key === "validate label new text");
    assert.ok(v, `${s}: the label composite is validated`);
    assert.ok(Math.abs((s === "prague" ? v.predicted : v.predictedExecutionGas) - c.E) <= 4, `${s}: the planner's E is the model's prediction up to rounding`);
  }
});

test("the Realm limits refuse before gas", () => {
  const model = formula3();
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

test("the stated maximum errors: all gas on every schedule, execution gas on amsterdam as its own field, each with its composite, and the bounds", () => {
  const model = committed();
  const pct = (pred, meas) => Number((((pred - meas) / meas) * 100).toFixed(2)) + 0; // + 0: JSON writes -0 as 0
  const worst = (rows, field) => rows.reduce((a, v) => (Math.abs(v[field]) > Math.abs(a[field]) ? v : a));
  const under = (rows, field) => { const v = rows.reduce((a, x) => (x[field] < a[field] ? x : a)); return v[field] < 0 ? [Number((-v[field]).toFixed(2)), v.key] : [0, null]; };
  for (const s of schedules(model)) {
    const p = model.profiles[s];
    for (const v of p.validation) assert.equal(v.errorPercent, pct(v.predicted, v.measured), `${s} ${v.key}: errorPercent is all gas`);
    // the maxima count every composite within the claim; beyondClaim ones are listed and excluded (maximaExcludeStates)
    const excluded = p.maximaExcludeStates ?? [];
    const rows = p.validation.filter((v) => !excluded.includes(v.state));
    if (model.laterLists) {
      assert.deepEqual(excluded, ["beyondClaim"], `${s}: only beyondClaim is excluded`);
      assert.ok(p.validation.some((v) => v.state === "beyondClaim"), `${s}: the beyond-the-claim composites are still reported`);
      assert.deepEqual([p.maxUnderErrorPercent, p.maxUnderErrorComposite], under(rows, "errorPercent"), `${s}: maxUnderErrorPercent names the largest under-prediction`);
      assert.ok(p.maxUnderErrorPercent <= model.planning.headroomPercent, `${s}: the all-gas under-prediction is inside the headroom`);
      if (s === "amsterdam") {
        assert.deepEqual([p.maxUnderExecutionErrorPercent, p.maxUnderExecutionErrorComposite], under(rows, "executionErrorPercent"), `${s}: maxUnderExecutionErrorPercent`);
        assert.ok(p.maxUnderExecutionErrorPercent <= model.planning.headroomPercent, `${s}: the execution-gas under-prediction (the cap condition's) is inside the headroom`);
      } else assert.equal(p.maxUnderExecutionErrorPercent, undefined);
    }
    const all = worst(rows, "errorPercent");
    assert.equal(p.maxAbsErrorPercent, Math.abs(all.errorPercent), `${s}: maxAbsErrorPercent`);
    assert.equal(p.maxAbsErrorComposite, all.key, `${s}: maxAbsErrorComposite names the composite that sets it`);
    const over = (field) => { const v = rows.reduce((a, x) => (x[field] > a[field] ? x : a)); return v[field] > 0 ? [Number(v[field].toFixed(2)), v.key] : [0, null]; };
    assert.deepEqual([p.maxOverErrorPercent, p.maxOverErrorComposite], over("errorPercent"), `${s}: maxOverErrorPercent names the largest over-prediction`);
    assert.equal(p.maxAbsErrorPercent, Math.max(p.maxUnderErrorPercent, p.maxOverErrorPercent), `${s}: maxAbsErrorPercent is the larger of under and over`);
    if (s === "prague") {
      // prague: the cap counts all gas, so over- and under-predictions of all gas are bounds
      assert.ok(p.maxAbsErrorPercent <= model.planning.headroomPercent, `${s}: the all-gas maximum is inside the headroom`);
      assert.equal(p.maxAbsExecutionErrorPercent, undefined, "prague has one figure: the cap counts all gas there");
      continue;
    }
    for (const v of p.validation) assert.equal(v.executionErrorPercent, pct(v.predictedExecutionGas, v.measuredExecutionGas), `${s} ${v.key}: executionErrorPercent`);
    const ex = worst(rows, "executionErrorPercent");
    assert.equal(p.maxAbsExecutionErrorPercent, Math.abs(ex.executionErrorPercent), `${s}: maxAbsExecutionErrorPercent`);
    assert.equal(p.maxAbsExecutionErrorComposite, ex.key, `${s}: maxAbsExecutionErrorComposite`);
    assert.ok(p.maxAbsExecutionErrorPercent <= model.planning.headroomPercent, `${s}: the execution-gas maximum (the cap condition's) is inside the headroom`);
    assert.deepEqual([p.maxOverExecutionErrorPercent, p.maxOverExecutionErrorComposite], over("executionErrorPercent"), `${s}: maxOverExecutionErrorPercent`);
    // amsterdam all gas: each composite inside its own bound (15% + its later statements' fresh-slot state gas)
    for (const v of rows) assert.ok(v.errorPercent <= v.allGasOverBoundPercent, `${s} ${v.key}: all-gas over-prediction ${v.errorPercent}% inside its bound ${v.allGasOverBoundPercent}%`);
    assert.match(model.planning.headroomCovers, /maxUnderExecutionErrorPercent/, "headroomCovers names the figure the cap condition is tested against on amsterdam");
    assert.match(model.planning.headroomCovers, /maxUnderErrorPercent/, "headroomCovers names the figure the cap condition is tested against on prague");
  }
});

test("the list tiers (laterLists): which row prices a later statement", () => {
  const lists = { shortTierMaxEntries: 48, claimEntries: 1024 };
  const c = { unbindTag: 1, unbindTagNewPlace: 2, unbindTagLongNewPlace: 3, unbindTagLongSamePlace: 4, unbindProperty: 5, unbindPropertyLongNewPlace: 6, unbindPropertyLongSamePlace: 7, bindFolderRebind: 8, bindFolderRebindNewPlace: 9, bindHeadRebind: 10 };
  const key = (a) => laterKey((k) => k in c, { kind: "bind", first: false, ...a }, lists);
  // short tier: a known count of at most 48
  assert.equal(key({ cost: "unbindTag", firstAtPlace: true, entries: 48 }), "unbindTagNewPlace");
  assert.equal(key({ cost: "unbindTag", firstAtPlace: false, entries: 1 }), "unbindTag");
  assert.equal(key({ cost: "unbindProperty", firstAtPlace: true, entries: 3 }), "unbindProperty", "a row measured at distinct subjects is its own new-place row");
  // long tier: more than 48, a count above the claim (still the 1,024 rows: the claim's cap, not a third tier), or unknown
  for (const entries of [49, 1025, 5000, undefined]) {
    assert.equal(key({ cost: "unbindTag", firstAtPlace: true, entries }), "unbindTagLongNewPlace");
    assert.equal(key({ cost: "unbindTag", firstAtPlace: false, entries }), "unbindTagLongSamePlace");
  }
  // omitted firstAtPlace is the dearer reading
  assert.equal(key({ cost: "unbindTag" }), "unbindTagLongNewPlace");
  assert.equal(key({ cost: "unbindTag", entries: 2 }), "unbindTagNewPlace");
  // re-binds never search the list: no tier, only their own new-place row when the model carries one
  assert.equal(key({ cost: "bindFolderRebind", firstAtPlace: true }), "bindFolderRebindNewPlace");
  assert.equal(key({ cost: "bindFolderRebind", firstAtPlace: false, entries: 4096 }), "bindFolderRebind");
  assert.equal(key({ cost: "bindHeadRebind", firstAtPlace: true }), "bindHeadRebind");
  // first statements are never tiered, and a model without laterLists prices by the row
  assert.equal(laterKey((k) => k in c, { cost: "unbindTag", first: true }, lists), "unbindTag");
  assert.equal(laterKey((k) => k in c, { cost: "unbindTag", first: false }, undefined), "unbindTag");
});

test("every list-tier row of the model comes in pairs and the planner reads the tier from the model", (t) => {
  const model = committed();
  if (!model.laterLists) return t.skip("the committed gas/model.json predates the list tiers (regenerate with pnpm run gas:model)");
  assert.equal(model.laterLists.shortTierMaxEntries, 48);
  assert.equal(model.laterLists.claimEntries, 1024);
  for (const s of schedules(model)) {
    const p = model.profiles[s];
    const exec = s === "prague" ? p.constants : p.split.executionGas;
    for (const c of [p.constants, exec, p.floor.kernel]) {
      for (const k of Object.keys(c).filter((x) => x.endsWith("LongNewPlace"))) {
        const row = k.slice(0, -"LongNewPlace".length);
        assert.ok(Number.isInteger(c[row]) && Number.isInteger(c[`${row}LongSamePlace`]), `${s}: ${row} has its row and both long rows`);
      }
    }
    const pl = planner(model, s);
    const one = (a) => pl.check([{ kind: "bind", cost: "unbindTag", first: false, ...a }]).E - exec.fixed;
    assert.equal(one({ firstAtPlace: true, entries: 2 }), exec.unbindTagNewPlace);
    assert.equal(one({ firstAtPlace: true }), exec.unbindTagLongNewPlace, "an unknown count is priced at the claim");
  }
});

test("the history-word correction is symmetric and reads the row's measured position (laterRows)", () => {
  const laterRows = { rows: { opens: { revisionBefore: 1, opensHistoryWord: true, target: "neverBound" }, closed: { revisionBefore: 2, opensHistoryWord: false, target: "same" } } };
  // revision before 1 or a positive multiple of 5 opens a word
  assert.deepEqual([0, 1, 2, 4, 5, 6, 10, 15].map(opensHistoryWord), [false, true, false, false, true, false, true, true]);
  assert.equal(historyWordAdds(laterRows, "opens", undefined), 0, "no revisionBefore: the row as it is");
  assert.equal(historyWordAdds(laterRows, "opens", 1), 0);
  assert.equal(historyWordAdds(laterRows, "opens", 2), -1, "the row opened a word, this position does not: subtract");
  assert.equal(historyWordAdds(laterRows, "opens", 5), 0);
  assert.equal(historyWordAdds(laterRows, "closed", 2), 0);
  assert.equal(historyWordAdds(laterRows, "closed", 5), 1, "the row opened none, this position does: add");
  assert.equal(historyWordAdds(null, "closed", 5), 0, "a model without laterRows");
  assert.throws(() => historyWordAdds(laterRows, "missing", 5), /laterRows has no missing/);
});

test("every later row of the committed model states its measured position, and the symmetric correction prices from the model", () => {
  const model = committed();
  if (!model.laterRows) return; // a model before the list release
  for (const s of schedules(model)) {
    const c = model.profiles[s].constants;
    for (const k of Object.keys(model.laterRows.rows)) assert.ok(k in c, `${s}: laterRows names ${k}, a constant`);
    for (const k of Object.keys(c).filter((k) => /^(unbind|release|restore)(Tag|Folder|Property|Same|Broader|Head)|AfterNo|Rebind|NumberChange/.test(k) && k !== "unbindTagLone")) {
      assert.ok(k in model.laterRows.rows, `${s}: ${k} has a measured position`);
    }
    const pl = planner(model, s);
    const exec = s === "prague" ? c : model.profiles[s].split.executionGas;
    // the symmetric correction on a yes after a lone no at revision 2 (no → release → yes)
    const yes = (revisionBefore) => [{ kind: "bind", cost: "bindTagAfterNo", first: false, entries: 1, revisionBefore }];
    assert.equal(pl.check(yes(2)).E - pl.check(yes(1)).E, 0 - exec.historyWordOpen + 0, `${s}: revision 2 subtracts one history word`);
  }
});
