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
