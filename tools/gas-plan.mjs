// SPDX-License-Identifier: MIT
// The planning rule of gas/model.json (design §10.4, tools/RELEASE.md "The planning rule"): a reference
// implementation for the SDK's write planner that reads ONLY gas/model.json, and the shapes whose largest admitted
// publication test/integration/FloorPlan.t.sol executes (test/vectors/floor-plan.json, written by tools/release.mjs).
//
// A publication is planned when it is inside the Realm limits and
//
//   max(E, V) ≤ floor(txGasCap × (100 − headroomPercent) / 100)
//
// E = the model's execution estimate (prague: constants; amsterdam: split.executionGas), and V the visible execution
// gas the kernel's floor checks need (floor.formula): V = max(K + prefixNeed(P), E) + ceil(F·64/63) + T, where K is the
// kernel's own execution gas (floor.kernel, the same model fitted with the index's callbacks removed), P and F the
// kernel's own quote (prefix floor and final reserve) from floor.workModel, floor.limits and floor.types, T the kernel
// tail, prefixNeed(P) = ceil((ceil(P·64/63) + dispatchOverhead)·64/63): the kernel forwards 63/64 of what it has above
// F + T to the ingress, which spends at most dispatchOverhead before forwarding 63/64 of what it has to the index.
//
// Planner actions (one per signed action, in order):
//   { kind: "publish", shape, bytes, fresh }  shape = a publishNew key ("files-root/1 form 0"); fresh = the record is new
//   { kind: "reuse", type }                   REUSE of an existing record of `type`
//   { kind: "create" } | { kind: "withdraw" }
//   { kind: "bind", cost, first, levels, purpose, firstAtPlace, entries }
//                                             any BIND, UNBIND or RELEASE: cost = a constants key ("bindTagFresh",
//                                             "unbindTagLone", "releaseTag", "bindPropertyFresh", "bindSameFreshWord",
//                                             "restoreBroader", ...), purpose = the action's purpose word (bytes32
//                                             hex; the work model's surcharge applies when it equals surchargePurpose;
//                                             omitted, it is read from the cost key: purposeOf), rebind = a BIND on
//                                             the author's BOUND head (omitted, read from the cost key: isRebind),
//                                             first = the author's head at the
//                                             position is UNSET (a first statement of either sign; false for every
//                                             later statement, a RELEASE always), levels = the
//                                             tagLevel counts of a first TAG statement ({ mineNew, mineExisting,
//                                             sharedNew, sharedExisting }; see tagLists.priceAsNew).
//                                             A later statement (first false) is priced by the list tiers
//                                             (laterLists, laterKey below): firstAtPlace = no earlier later
//                                             statement of this publication is at the same place (purpose, subject)
//                                             (omitted: true, the dearer reading); entries = the author's entry
//                                             count at that place, the length of its own scope list there, from a
//                                             read the planner trusts (omitted: unknown, priced at the claim's tier)
import assert from "node:assert/strict";

const ceilDiv = (a, b) => Math.floor((a + b - 1) / b);
const words = (n) => Math.ceil(n / 32);
const typeOf = (shape) => shape.split(" ")[0];
/** The purpose words, keccak("efs/purpose/<name>/1") (tools/deploy-plan.mjs PURPOSE; tools/test/gas-plan.test.mjs checks
 *  the two agree), written out so the planner imports nothing. */
export const PURPOSE = {
  HEAD: "0x2aff50c30ebccff5d8992943840917312d756200f3a504ececd8a3265ed547ee",
  FOLDER: "0x8316732a0c2362b6d10c2442783a1b6b974d8647b23379f9dee65b576fa4afcf",
  TAG: "0x0c188a98152f479eeaea5b4d414383b83c66920c872f6eac8d681113dd6f65db",
  PROPERTY: "0x2f6e2c067a273babd6f052511fa0fbbefd946138147520281191a783c01d2243",
  SAME: "0x8e965fe46a3481cd6db64a45fda63e6e7b7a8dbf42024371aab1f405f1fa861e",
  BROADER: "0xf064225e057dbfc2c1a00dc847d06a7486d76609e9e32838546890d91eeb3b97",
};
/** Whether a planner bind action is a re-bind (a BIND on a BOUND head: a new target or a new number on the same
 *  target): its `rebind`, else read from its constants key. */
export const isRebind = (a) => a.rebind ?? /Rebind|NumberChange/.test(a.cost);
/** A planner bind action's purpose word: its `purpose`, else the purpose its constants key names. */
export function purposeOf(a) {
  if (a.purpose) return a.purpose;
  const k = a.cost;
  const name = /Head/.test(k) ? "HEAD" : /Folder/.test(k) ? "FOLDER" : /Tag/.test(k) ? "TAG" : /Property/.test(k) ? "PROPERTY"
    : /Same/.test(k) ? "SAME" : /Broader/.test(k) ? "BROADER" : null;
  assert.ok(name, `no purpose for constants key ${k}`);
  return PURPOSE[name];
}

/** The constants key that prices a LATER statement (`a.first` false) under `laterLists` (design §10.4; tools/RELEASE.md
 *  "The list tiers"). `has(key)` says whether the constants carry `key`. A row with list-tier rows (`<cost>LongNewPlace`)
 *  in the short tier (a known `entries` ≤ shortTierMaxEntries) is its own row, or `<cost>NewPlace` for the first later
 *  statement at its place when the model carries one; in the long tier (more entries, or `entries` unknown) it is
 *  `<cost>LongNewPlace` for the first later statement at its place and `<cost>LongSamePlace` for the rest. A row without
 *  list-tier rows (a re-bind: it never searches the list) has no tier: `<cost>NewPlace` when first at its place and the
 *  model carries one, else its own row. A model without `laterLists` prices every later statement by its row. */
export function laterKey(has, a, laterLists) {
  const k = a.cost;
  if (a.first || !laterLists) return k;
  const firstAtPlace = a.firstAtPlace ?? true;
  if (has(`${k}LongNewPlace`)) {
    const short = Number.isInteger(a.entries) && a.entries <= laterLists.shortTierMaxEntries;
    if (!short) return firstAtPlace ? `${k}LongNewPlace` : `${k}LongSamePlace`;
  }
  return firstAtPlace && has(`${k}NewPlace`) ? `${k}NewPlace` : k;
}

/** `tagLists.priceAsNew`: whether a roll-up list holding `entries` entries is priced as a new list. */
export function priceAsNew(model, entries) {
  const r = model.tagLists.priceAsNew;
  return r.entries.includes(entries) || entries % r.entriesMultipleOf === 0;
}

/** The planner of one fee schedule ("prague" | "amsterdam"), from the model alone. */
export function planner(model, schedule) {
  const p = model.profiles[schedule];
  assert.ok(p, `gas/model.json has no ${schedule} profile`);
  const exec = schedule === "prague" ? p.constants : p.split.executionGas;
  const { floor } = p;
  const { workModel: wm, limits, kernel } = floor;
  const plan = model.planning;
  const cost = (c, a) => {
    switch (a.kind) {
      case "publish":
        return a.fresh ? c.publishNew[a.shape] + c.perWord * words(a.bytes) + c.perByte * a.bytes : c.publishExisting;
      case "reuse": return c.reuse;
      case "create": return c.create;
      case "withdraw": return c.withdraw;
      case "bind": {
        const key = laterKey((k) => k in c, a, model.laterLists);
        assert.ok(key in c, `no constant ${key}`);
        let g = c[key];
        for (const [k, n] of Object.entries(a.levels ?? {})) g += c.tagLevel[k] * n;
        return g;
      }
      default: throw new Error(`unknown planner action ${a.kind}`);
    }
  };
  const estimate = (c, actions, firstWrite) => c.fixed + (firstWrite ? c.firstWriteSurcharge : 0) + actions.reduce((s, a) => s + cost(c, a), 0);

  assert.equal(wm.formulaVersion, 3, "gas/model.json: the planner implements work-model formula 3");
  /** Adds one row of the work model (formula 3): First, Rebind or Later, and the surcharge's row of the same class. */
  const row = (acc, cls, surcharged) => {
    const k = cls === "Rebind" ? "Rebind" : `Bind${cls}`; // freshPerRebind, freshPerBindFirst, freshPerBindLater
    acc.fresh10 += wm[`freshPer${k}`];
    acc.rw10 += wm[`rwPer${k}`];
    acc.compute += wm[`computePer${k}`];
    if (surcharged) {
      acc.fresh10 += wm[`surchargeFresh${cls}`];
      acc.rw10 += wm[`surchargeRw${cls}`];
      acc.compute += wm[`surchargeCompute${cls}`];
    }
  };
  const zeroPurpose = /^0x0{64}$/;
  /** The kernel's own quote (LedgerIngress._foldAndQuote, design §10.4, work-model formula 3), exactly. */
  function quote(actions) {
    const acc = { fresh10: wm.freshPerPublication, rw10: wm.rwPerPublication, compute: wm.computeBase + wm.computePerAction * actions.length };
    let binds = 0;
    let publishes = 0;
    let withdraws = 0;
    for (const a of actions) {
      if (a.kind === "publish" || a.kind === "reuse") {
        const t = floor.types[a.kind === "publish" ? typeOf(a.shape) : a.type];
        assert.ok(t, `floor.types has no ${a.shape ?? a.type}`);
        // a REUSE always names an existing record
        if (a.kind === "publish" && a.fresh) acc.fresh10 += wm.freshPerPublishFresh + wm.freshPerDigestSpec * t.specs;
        else acc.fresh10 += wm.freshPerPublishExisting;
        acc.rw10 += wm.rwPerPublish;
        acc.fresh10 += wm.freshPerRef * t.refs;
        ++publishes;
      } else if (a.kind === "bind") {
        ++binds;
        // first: the author's head at the position is UNSET (never for a RELEASE); every other one is a later statement
        const surcharged = !zeroPurpose.test(wm.surchargePurpose) && purposeOf(a).toLowerCase() === wm.surchargePurpose.toLowerCase();
        row(acc, a.first ? "First" : isRebind(a) ? "Rebind" : "Later", surcharged);
      } else if (a.kind === "withdraw") {
        // the first WITHDRAW of a publication is covered by the per-publication terms; every later one is a later row
        if (withdraws++ !== 0) row(acc, "Later", false);
      }
    }
    const freshSlots = ceilDiv(acc.fresh10, 10);
    const rewrites = ceilDiv(acc.rw10, 10);
    const prefixFloor = acc.compute + freshSlots * limits.floorFreshGas + rewrites * limits.floorRewriteGas;
    const finalReserve = wm.finalComputeBase + wm.finalComputePerBind * binds + wm.finalComputePerPublish * publishes;
    return { prefixFloor, finalReserve, freshSlots, rewrites, binds, publishes };
  }

  const { numerator: num, denominator: den } = floor.callGasRetained;
  /** Visible gas needed at a callback so that `remaining` prefix floor passes both 63/64 steps. */
  const prefixNeed = (remaining) => ceilDiv((ceilDiv(remaining * den, num) + floor.dispatchOverhead) * den, num);
  /** V from measured or modelled E and K and the kernel's quote. */
  const visible = (E, K, q) => Math.max(K + prefixNeed(q.prefixFloor), E) + ceilDiv(q.finalReserve * den, num) + limits.kernelTail;
  const budget = Math.floor((plan.txGasCap * (100 - plan.headroomPercent)) / 100);

  /** The rule's verdict on one publication (`firstWrite`: the principal has never written). */
  function check(actions, { firstWrite = false } = {}) {
    const q = quote(actions);
    const E = Math.round(estimate(exec, actions, firstWrite));
    const K = Math.round(estimate(kernel, actions, firstWrite));
    const V = visible(E, K, q);
    const bodyBytes = actions.reduce((s, a) => s + (a.kind === "publish" ? a.bytes : 0), 0);
    const L = plan.limits;
    const refused = actions.length < 1 ? "empty"
      : actions.length > L.maxActions ? "maxActions"
      : q.binds > L.maxBindsPerPublication ? "maxBindsPerPublication"
      : bodyBytes > L.maxBodyBytesPerPublication ? "maxBodyBytesPerPublication"
      : Math.max(E, V) > budget ? "gas" : null;
    return { fits: refused === null, refused, E, K, V, budget, bodyBytes, ...q };
  }

  /** The largest k (0 when none) for which `shape(k)` is planned, checking every k from 1 (shapes need not be monotone). */
  function largest(shape, max = plan.limits.maxActions) {
    let best = 0;
    for (let k = 1; k <= max; k++) {
      const acts = shape(k);
      if (acts.length > plan.limits.maxActions) break;
      if (check(acts).fits) best = k;
    }
    return best;
  }

  return { quote, check, largest, visible, prefixNeed, budget };
}

// ---- the shapes of test/integration/FloorPlan.t.sol ------------------------------------------------------------------
// Each maps k (the shape's unit count) to planner actions; the Solidity builders of the same name write the same
// actions in the same state. `units` is how many actions one unit is.

const range = (k) => [...Array(k).keys()];
/** k first TAG statements on the deepest topic of one `depth`-word path, every position fresh (another author has never
 *  stated there), the author's and the shared roll-ups at each proper ancestor holding `mine0` + j and j entries before
 *  tag j (case i: everything new, mine0 = 0). */
const firstTagsNew = (model, depth) => (k) => range(k).map((j) => {
  const mine = priceAsNew(model, j) ? "mineNew" : "mineExisting";
  const shared = priceAsNew(model, j) ? "sharedNew" : "sharedExisting";
  return { kind: "bind", cost: "bindTagFresh", first: true, levels: depth > 1 ? { [mine]: depth - 1, [shared]: depth - 1 } : {} };
});
/** The first tags another author states before the second-author shapes: one at each of their positions. */
export const OTHER_FIRST_TAGS = 64;
/** k first TAG statements (first yeses) at existing positions: another author first tagged OTHER_FIRST_TAGS things on
 *  the topic, this author then mine0 other things, and tag j is about the other author's thing j. Before tag j the
 *  author's roll-up at each proper ancestor holds mine0 + j entries and the shared one OTHER_FIRST_TAGS + mine0 + j (a
 *  first yes files there at an existing position too). Case iii: mine0 = 0; case iv: mine0 = 6. */
const firstTagsSecond = (model, depth, mine0) => (k) => range(k).map((j) => {
  const mine = priceAsNew(model, mine0 + j) ? "mineNew" : "mineExisting";
  const shared = priceAsNew(model, OTHER_FIRST_TAGS + mine0 + j) ? "sharedNew" : "sharedExisting";
  return { kind: "bind", cost: "bindTagSecondAuthor", first: true, levels: depth > 1 ? { [mine]: depth - 1, [shared]: depth - 1 } : {} };
});
const repeat = (a) => (k) => range(k).map(() => ({ ...a }));
/** k later statements `cost` at ONE place (FloorPlan.t.sol's topic or root folder) whose author's list holds
 *  min(k + 1, 64) entries before them (the builder states one more thing than it later changes, at most 64): the first
 *  is the first later statement at that place, the rest are not. */
const atOnePlace = (cost) => (k) => range(k).map((j) => ({ kind: "bind", cost, first: false, firstAtPlace: j === 0, entries: Math.min(k + 1, 64) }));

/** FloorPlan.t.sol's create-file recipe: CREATE, PUBLISH files-root/1 form 0 (64-byte header + 18-byte document),
 *  PUBLISH a 10-byte files-name/3, BIND HEAD (first), BIND FOLDER (first entry of that name in the root). */
export const CREATE_FILE_ROOT_BYTES = 82;
export const CREATE_FILE_NAME_BYTES = 10;
/** FloorPlan.t.sol's registration chunk: one PUBLISH of a fresh 12-byte topic-word/1 page per unit. */
export const WORD_PAGE_BYTES = 12;

/** FloorPlan.t.sol's name records: a 10-byte files-name/3 (`np-xyz.md0`-style, distinct per unit). */
export const NAME_BYTES = 10;

export function shapes(model) {
  return {
    loneNegatives: { what: "lone negatives (first masks) on a one-word topic", units: 1, of: repeat({ kind: "bind", cost: "unbindTagLone", first: true }) },
    firstTagsDepth8New: { what: "first tags on one new 8-word path, every position and roll-up new (case i)", units: 1, depth: 8, of: firstTagsNew(model, 8) },
    firstTagsDepth64New: { what: "first tags on one new 64-word path, every position and roll-up new (case i)", units: 1, depth: 64, of: firstTagsNew(model, 64) },
    firstTagsDepth8Existing: { what: "first tags at existing positions of an 8-word topic, the author's roll-ups existing (case iv)", units: 1, depth: 8, of: firstTagsSecond(model, 8, 6) },
    firstTagsDepth64Existing: { what: "first tags at existing positions of a 64-word topic, the author's roll-ups existing (case iv)", units: 1, depth: 64, of: firstTagsSecond(model, 64, 6) },
    secondAuthorDepth8: { what: "a second author's first tags at existing positions of an 8-word topic, its roll-ups new (case iii)", units: 1, depth: 8, of: firstTagsSecond(model, 8, 0) },
    tagMasks: { what: "masks of asserted tags on a one-word topic (UNBIND from BOUND)", units: 1, of: atOnePlace("unbindTag") },
    tagReleases: { what: "releases of asserted tags on a one-word topic", units: 1, of: atOnePlace("releaseTag") },
    tagRestores: { what: "restores of masked tags on a one-word topic (BIND from MASKED)", units: 1, of: atOnePlace("restoreTag") },
    tagNumberChanges: { what: "number changes on asserted tags on a one-word topic (a REBIND to the same target with a new number)", units: 1, of: atOnePlace("bindTagNumberChange") },
    masksOfMasks: { what: "masks of masks on a one-word topic (UNBIND from MASKED with a new number; priced as masks of asserted tags, an upper bound)", units: 1, of: atOnePlace("unbindTag") },
    folderRebinds: { what: "re-binds of root-folder entries to another file", units: 1, of: atOnePlace("bindFolderRebind") },
    repeatPublishes: { what: "repeat PUBLISHes of existing 10-byte files-name/3 records", units: 1, of: repeat({ kind: "publish", shape: "files-name/3", bytes: NAME_BYTES, fresh: false }) },
    nameRecords: { what: "fresh 10-byte files-name/3 records (publish-heavy)", units: 1, of: repeat({ kind: "publish", shape: "files-name/3", bytes: NAME_BYTES, fresh: true }) },
    publishesAndTags: {
      what: "a fresh 10-byte name record and a first tag on a one-word topic per unit (2 actions each)", units: 2,
      of: (k) => range(k).flatMap(() => [
        { kind: "publish", shape: "files-name/3", bytes: NAME_BYTES, fresh: true },
        { kind: "bind", cost: "bindTagFresh", first: true, levels: {} },
      ]),
    },
    registrationChunk: { what: "a registration chunk: fresh 12-byte topic-word/1 pages", units: 1, of: repeat({ kind: "publish", shape: "topic-word/1", bytes: WORD_PAGE_BYTES, fresh: true }) },
    createFiles: {
      what: "create-file recipes into the root folder (5 actions each)", units: 5,
      of: (k) => range(k).flatMap(() => [
        { kind: "create" },
        { kind: "publish", shape: "files-root/1 form 0", bytes: CREATE_FILE_ROOT_BYTES, fresh: true },
        { kind: "publish", shape: "files-name/3", bytes: CREATE_FILE_NAME_BYTES, fresh: true },
        { kind: "bind", cost: "bindHeadFresh", first: true },
        { kind: "bind", cost: "bindFolderFreshFile", first: true },
      ]),
    },
  };
}

/** test/vectors/floor-plan.json: per schedule and shape, the largest planned count and the rule's figures for it and for
 *  one unit more (which the rule must refuse, or which exceeds the action limit). */
export function planVectors(model) {
  const out = { schema: "efs/vectors/floor-plan/1", note: "Written by tools/release.mjs from gas/model.json with tools/gas-plan.mjs (the planning rule); read by test/integration/FloorPlan.t.sol, which builds each shape at `k`, checks the kernel's quote equals `prefixFloor`/`finalReserve`, and proves the publication admitted under the per-transaction cap.", schedules: {} };
  for (const schedule of Object.keys(model.profiles)) {
    const pl = planner(model, schedule);
    const rows = {};
    for (const [name, s] of Object.entries(shapes(model))) {
      const max = Math.floor(model.planning.limits.maxActions / s.units);
      const k = pl.largest(s.of, max);
      assert.ok(k > 0, `${schedule} ${name}: the rule plans no publication of this shape`);
      const at = pl.check(s.of(k));
      const next = (k + 1) * s.units <= model.planning.limits.maxActions ? pl.check(s.of(k + 1)) : null;
      if (next) assert.equal(next.fits, false, `${schedule} ${name}: k + 1 planned, so k is not the largest`);
      const pick = (c) => ({ E: c.E, K: c.K, V: c.V, prefixFloor: c.prefixFloor, finalReserve: c.finalReserve, freshSlots: c.freshSlots, rewrites: c.rewrites });
      rows[name] = {
        what: s.what, units: s.units, ...(s.depth ? { depth: s.depth } : {}), k, actions: k * s.units, budget: at.budget, ...pick(at),
        next: next ? { k: k + 1, refused: next.refused, ...pick(next) } : { k: k + 1, refused: "maxActions" },
      };
    }
    out.schedules[schedule] = rows;
  }
  return out;
}
