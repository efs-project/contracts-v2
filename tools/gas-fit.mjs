// SPDX-License-Identifier: MIT
// The anchor rule of gas/model.json's fixed term (tools/gas-model.mjs; tools/RELEASE.md "The planning model"): a new
// measured row never changes the price of an existing action. `fixed` is the median of 2·gas(k = 1) − gas(k = 2) over
// the ANCHOR pairs only: the pairs the model had at 899767e, frozen here. A pair added later is fitted as its own
// constant and its implied fixed cost is still recorded (fit.impliedFixedByPair), but it is not an anchor, so it cannot
// move `fixed` and with it every prediction. Changing this list re-prices every action; do it only on purpose.
import assert from "node:assert/strict";

/** The k1/k2 pair keys whose implied fixed cost anchors `fixed` (the model's pairs at 899767e). */
export const FIXED_ANCHORS = Object.freeze([
  // files-bytes/1 at every measured size
  "pub bytes 64", "pub bytes 100", "pub bytes 1000", "pub bytes 1024", "pub bytes 4096", "pub bytes 8192",
  // every other PUBLISH shape
  "pub span", "pub content c0", "pub content c2", "pub external 40", "pub external 400", "pub directory",
  "pub name 12", "pub name 200", "pub root f0", "pub root f1", "pub child f0", "pub child f1",
  "pub topic word 12", "pub topic word 40", "pub topic", "pub text 24",
  // the other actions
  "pub existing", "reuse", "create", "bind head fresh", "bind head rebind", "bind folder fresh file",
  "bind folder fresh dir", "bind folder rebind", "unbind folder", "release folder", "bind tag fresh",
  "bind tag second author", "bind tag number change", "unbind tag lone", "unbind tag", "release tag", "restore tag",
  "withdraw",
]);

export const median = (xs) => { const s = [...xs].sort((a, b) => a - b); const m = s.length >> 1; return s.length % 2 ? s[m] : (s[m - 1] + s[m]) / 2; };

/** `fixed` from the implied fixed cost of every pair (`{ pairKey: 2·k1 − k2 }`): the median over the anchors only. */
export function fixedFrom(impliedFixedByPair) {
  for (const k of FIXED_ANCHORS) assert.ok(Number.isFinite(impliedFixedByPair[k]), `no anchor pair "${k}" (FIXED_ANCHORS in tools/gas-fit.mjs)`);
  return median(FIXED_ANCHORS.map((k) => impliedFixedByPair[k]));
}

// ---- the stated bound (tools/gas-model.mjs refuses a model that breaks it; the integration owner's ruling of 2026-11-26)
// UNDER-predictions are bounded at limitPercent everywhere (all gas on every schedule, execution gas on amsterdam).
// OVER-predictions are bounded at limitPercent on the gas the 2^24 cap counts: all gas on prague, execution gas on
// amsterdam. Amsterdam's ALL-gas over-prediction is bounded per composite at limitPercent plus, over its measured gas,
// its count of later statements × one fresh slot's state gas (the schedule's freshSlot.stateGas): a later row is
// measured at the dearest state of lists a planner cannot see (a backlink or history word that opens), and on amsterdam
// one such word is a fresh slot of state gas and no execution gas, so a composite whose statements open none is
// over-stated by up to one slot a statement. A composite over-predicted for any other reason is refused as before.

/** The all-gas over-prediction bound of one amsterdam composite, in percent of its measured gas. */
export function allGasOverBoundPercent(v, limitPercent, freshSlotStateGas) {
  return limitPercent + ((v.laterStatements ?? 0) * freshSlotStateGas * 100) / v.measured;
}

/** Every bound a profile's composites break (empty when none), for the composites the maxima count. A composite whose
 *  state is in `underOnlyStates` (excluded from the maxima, gas/model.json `midList`) is still held to `limitPercent` of
 *  UNDER-prediction, on all gas and, on amsterdam, on execution gas. */
export function overBound(profiles, { limitPercent, freshSlotStateGas, underOnlyStates = [] }) {
  const out = [];
  for (const [name, p] of Object.entries(profiles)) {
    const amsterdam = name === "amsterdam";
    for (const k of ["maxUnderErrorPercent", "maxUnderExecutionErrorPercent", ...(amsterdam ? ["maxOverExecutionErrorPercent"] : ["maxOverErrorPercent"])]) {
      if (p[k] !== undefined && p[k] > limitPercent) out.push(`${name} ${k} ${p[k]}% exceeds ${limitPercent}%`);
    }
    for (const v of p.validation) {
      if (underOnlyStates.includes(v.state)) {
        if (-v.errorPercent > limitPercent) out.push(`${name} "${v.key}" (${v.state}) predicted ${v.predicted}, measured ${v.measured}: under-predicted ${-v.errorPercent}%, over ${limitPercent}%`);
        if (v.executionErrorPercent !== undefined && -v.executionErrorPercent > limitPercent) out.push(`${name} "${v.key}" (${v.state}) execution gas predicted ${v.predictedExecutionGas}, measured ${v.measuredExecutionGas}: under-predicted ${-v.executionErrorPercent}%, over ${limitPercent}%`);
        continue;
      }
      if ((p.maximaExcludeStates ?? []).includes(v.state)) continue;
      if (-v.errorPercent > limitPercent) out.push(`${name} "${v.key}" predicted ${v.predicted}, measured ${v.measured}: under-predicted ${-v.errorPercent}%, over ${limitPercent}%`);
      if (v.executionErrorPercent !== undefined && Math.abs(v.executionErrorPercent) > limitPercent) out.push(`${name} "${v.key}" execution gas predicted ${v.predictedExecutionGas}, measured ${v.measuredExecutionGas}: ${v.executionErrorPercent}% exceeds ±${limitPercent}%`);
      if (!amsterdam && v.errorPercent > limitPercent) out.push(`${name} "${v.key}" predicted ${v.predicted}, measured ${v.measured}: over-predicted ${v.errorPercent}%, over ${limitPercent}%`);
      if (amsterdam) {
        const bound = allGasOverBoundPercent(v, limitPercent, freshSlotStateGas);
        if (v.errorPercent > bound) out.push(`${name} "${v.key}" all gas over-predicted ${v.errorPercent}%, over its bound ${bound.toFixed(2)}% (${limitPercent}% + ${v.laterStatements ?? 0} later statements × ${freshSlotStateGas} state gas)`);
      }
    }
  }
  return out;
}
