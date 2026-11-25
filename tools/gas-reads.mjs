// SPDX-License-Identifier: MIT
// gas/model.json `reads`: what the topic readers' views cost a caller and the bounds that keep one read call under a
// gas cap (docs/TAG-NUMBERS.md "Reads"). Imported by tools/gas-model.mjs, which writes it beside the publication model
// and, with `--check 1`, compares the measured rows exactly (gas is deterministic for identical bytecode).
//
// It runs test/integration/TopicReadMeasure.t.sol with `--json -vv` under the default profile (prague, out/) and, unless
// skipped, the `amsterdam` profile (out/amsterdam, cache/amsterdam), reads every "tr <key>: <gas>" line (one cold
// `view` call each: every account cooled first, the call frame's gas, no intrinsic, no calldata) and fits, per schedule:
//
//   mine (exact or below) = opening + openingPerLensAuthor·L + Σ over rows (perRow + perLensIndex·(j + 1))
//     j the row's deciding lens index (a row of lens author j reads the heads of lens[0..j]); least squares over the
//     four lens sizes and two page sizes of the measured round-robin fixture, negative terms clamped to 0
//   everyone (exact or below) = opening + Σ over rows (perRow + perLensAuthor·L) + Σ over skipped entries perSkipped
//     the lens term from the lens-8 page against `raw` (no lens); a skipped entry (nobody says yes) reads no lens
//   raw, about, byName, wordPage, children = opening + perRow·rows
//
// and the bounds: the most rows (every entry a row decided by the last lens author, the worst case) and the most
// skipped entries one call can read under `budget` = callGasCap × (100 − marginPercent) / 100.
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { root } from "./deploy-plan.mjs";

export const READS_SUITE = "test/integration/TopicReadMeasure.t.sol";
const CALL_GAS_CAP = 10_000_000;
const MARGIN_PERCENT = 10;
const LENSES = [1, 8, 16, 32, 64];
const THINGS = 50; // TopicReadMeasure.THINGS

function runReads(profile) {
  const env = { ...process.env, FOUNDRY_PROFILE: profile, FOUNDRY_GAS_LIMIT: "100000000000" };
  if (profile !== "default") Object.assign(env, { FOUNDRY_OUT: `out/${profile}`, FOUNDRY_CACHE_PATH: `cache/${profile}` });
  const r = spawnSync("perl", ["-e", "alarm 5400; exec @ARGV", "forge", "test", "--match-path", READS_SUITE, "--json", "-vv"], { cwd: root, env, encoding: "utf8", timeout: 5_400_000, maxBuffer: 256 << 20 });
  const start = r.stdout.indexOf("{");
  assert.ok(start >= 0, `forge test (${profile}, reads) printed no JSON (exit ${r.status}): ${r.stderr.slice(-3000)}`);
  const json = JSON.parse(r.stdout.slice(start));
  const rows = {};
  for (const result of Object.values(json)) {
    for (const [test, res] of Object.entries(result.test_results)) {
      assert.equal(res.status, "Success", `${profile} reads: ${test} ${res.status} ${res.reason ?? ""}`);
      for (const line of res.decoded_logs ?? []) {
        const m = line.match(/^tr (.*): (\d+)$/);
        if (m) rows[m[1]] = Number(m[2]);
      }
    }
  }
  return Object.fromEntries(Object.entries(rows).sort(([a], [b]) => a.localeCompare(b)));
}

/** Least squares by the normal equations (a handful of unknowns). */
function lsq(A, b) {
  const n = A[0].length;
  const M = Array.from({ length: n }, (_, i) => Array.from({ length: n }, (_, j) => A.reduce((s, r) => s + r[i] * r[j], 0)));
  const v = Array.from({ length: n }, (_, i) => A.reduce((s, r, k) => s + r[i] * b[k], 0));
  for (let i = 0; i < n; i++) {
    let p = i;
    for (let r = i + 1; r < n; r++) if (Math.abs(M[r][i]) > Math.abs(M[p][i])) p = r;
    [M[i], M[p]] = [M[p], M[i]];
    [v[i], v[p]] = [v[p], v[i]];
    for (let r = 0; r < n; r++) {
      if (r === i) continue;
      const f = M[r][i] / M[i][i];
      for (let c = 0; c < n; c++) M[r][c] -= f * M[i][c];
      v[r] -= f * v[i];
    }
  }
  return v.map((x, i) => x / M[i][i]);
}

const round = Math.round;
const need = (rows, key) => {
  assert.ok(Number.isInteger(rows[key]), `no "tr ${key}" measurement`);
  return rows[key];
};

function mineFit(rows, depth) {
  const A = [];
  const b = [];
  for (const L of [1, 8, 32, 64]) {
    for (const page of [10, 50]) {
      let js = 0; // rows newest first: things THINGS-1 .. THINGS-page, thing i filed by lens author i mod L
      for (let i = THINGS - 1; i >= THINGS - page; i--) js += (i % L) + 1;
      A.push([1, L, page, js]);
      b.push(need(rows, `mine lens=${L} depth=${depth} page=${page}`));
    }
  }
  const [o0, o1, a, k] = lsq(A, b).map((x) => Math.max(0, round(x)));
  const err = Math.max(...A.map((r, i) => Math.abs(o0 * r[0] + o1 * r[1] + a * r[2] + k * r[3] - b[i]) / b[i]));
  return { opening: o0, openingPerLensAuthor: o1, perRow: a, perLensIndex: k, maxAbsErrorPercent: Number((err * 100).toFixed(1)) };
}

const linear = (rows, key, lo, hi, unit) => {
  const g1 = need(rows, `${key}${lo}`);
  const g2 = need(rows, `${key}${hi}`);
  const per = round((g2 - g1) / (unit[1] - unit[0]));
  return { opening: g1 - per * unit[0], perRow: per };
};

function schedule(rows) {
  const rawExact = linear(rows, "raw exact page=", 10, 50, [10, 50]);
  const rawBelow = linear(rows, "raw below page=", 10, 50, [10, 50]);
  const evExact = linear(rows, "everyone exact lens=8 page=", 10, 50, [10, 50]);
  const evBelow = linear(rows, "everyone below lens=8 page=", 10, 50, [10, 50]);
  const skipped = (view) => Object.fromEntries([1, 8, 64].map((L) => [L, need(rows, `skip ${view} lens=${L} per entry`)]));
  const terms = {
    mineExact: mineFit(rows, 1),
    mineBelow: mineFit(rows, 8),
    everyoneExact: { opening: rawExact.opening, perRow: rawExact.perRow, perLensAuthor: round((evExact.perRow - rawExact.perRow) / 8), perSkippedEntryByLens: skipped("exact") },
    everyoneBelow: { opening: rawBelow.opening, perRow: rawBelow.perRow, perLensAuthor: round((evBelow.perRow - rawBelow.perRow) / 8), perSkippedEntryByLens: skipped("below") },
    rawExact,
    rawBelow,
    byName: linear(rows, "byName 300 authors page=", 10, 50, [10, 50]),
    about: linear(rows, "about page=", 10, 20, [10, 20]),
    wordPage: linear(rows, "wordPage places=", 5, 20, [5, 20]),
    children: { opening: need(rows, "children page=1") - round((need(rows, "children 16") - need(rows, "children page=1")) / 15), perRow: round((need(rows, "children 16") - need(rows, "children page=1")) / 15) },
  };
  const budget = (CALL_GAS_CAP * (100 - MARGIN_PERCENT)) / 100;
  const fit = (opening, row) => Math.max(0, Math.floor((budget - opening) / row));
  const bounds = {};
  for (const L of LENSES) {
    const m = (t) => fit(t.opening + t.openingPerLensAuthor * L, t.perRow + t.perLensIndex * L);
    const skip = (t) => Math.max(...Object.values(t.perSkippedEntryByLens));
    const e = (t) => ({ maxRows: fit(t.opening, t.perRow + t.perLensAuthor * L), maxSkippedEntries: fit(t.opening, skip(t)) });
    bounds[L] = { mineExact: { maxRows: m(terms.mineExact) }, mineBelow: { maxRows: m(terms.mineBelow) }, everyoneExact: e(terms.everyoneExact), everyoneBelow: e(terms.everyoneBelow) };
  }
  const product = (view) => Math.min(...LENSES.filter((L) => L >= 8).map((L) => bounds[L][view].maxRows * L));
  const recommended = {
    pageTimesLens: { mineExact: product("mineExact"), mineBelow: product("mineBelow"), everyoneExact: product("everyoneExact"), everyoneBelow: product("everyoneBelow") },
    maxRows: Math.min(150, ...["mineExact", "everyoneExact"].map((v) => bounds[1][v].maxRows)),
    limitEntries: Math.min(...["everyoneExact", "everyoneBelow"].map((v) => bounds[64][v].maxSkippedEntries)),
  };
  return { rows, terms, bounds, recommended };
}

/** The `reads` section: both schedules (amsterdam unless skipped). */
export function measureReads({ amsterdam }) {
  const schedules = { prague: schedule(runReads("default")) };
  if (amsterdam) schedules.amsterdam = schedule(runReads("amsterdam"));
  return {
    note: "Planning only: what one cold topic-reader view call costs (no intrinsic, no calldata) and the bounds that keep one call under callGasCap. Per-row terms are the same on both schedules (reads are not repriced); amsterdam's openings carry about 4k more of cold accounts. A skipped entry of `everyone` (nobody says yes) reads its cell and its author-list head and no lens, so its cost does not grow with the lens (it was 49k at a lens of 1, 357k at 64 exact and 1.56M at 64 below when the lens was read first).",
    suite: READS_SUITE,
    callGasCap: CALL_GAS_CAP,
    marginPercent: MARGIN_PERCENT,
    method: {
      measurement: "one cold view call per row of the suite: vm.cool on every account the call can touch, then vm.lastCallGas().gasTotalUsed",
      mine: "gas = opening + openingPerLensAuthor·L + Σ over rows (perRow + perLensIndex·(j + 1)), j the deciding lens index; least squares over lens 1, 8, 32, 64 and pages 10, 50 of the round-robin fixture (mineExact: filed at the place; mineBelow: under a descendant, with the viewed-place heads of lens[0..j]); negative terms clamped to 0",
      everyone: "gas = opening + Σ over rows (perRow + perLensAuthor·L) + Σ over skipped entries perSkippedEntry; perRow and opening from raw (no lens), perLensAuthor from the lens-8 page (every lens head read: no lens author has a stance), perSkippedEntryByLens from a padded place (lone negatives, lens 1, 8 and 64)",
      bounds: "budget = callGasCap × (100 − marginPercent) / 100; maxRows = floor((budget − opening(L)) / worst row(L)), the worst row decided by the last lens author (j + 1 = L); maxSkippedEntries = floor((budget − opening) / the largest perSkippedEntry); a page that mixes both stays under budget while opening + rows·row(L) + skipped·perSkippedEntry ≤ budget",
      recommended: "pageTimesLens: the smallest maxRows·L over lens 8..64 per view (keep maxRows·L at or below it); maxRows: at most 150 rows per call; limitEntries: the most entries one `everyone` call reads when none is a row, at a lens of 64",
    },
    schedules,
  };
}

/** --check: the measured rows equal the committed ones exactly, per measured schedule. */
export function checkReads(committed, fresh) {
  const out = [];
  if (!committed) return ["reads: absent from the committed gas/model.json"];
  for (const [name, s] of Object.entries(fresh.schedules)) {
    const c = committed.schedules?.[name];
    if (!c) {
      out.push(`reads.schedules.${name}: absent from the committed gas/model.json`);
      continue;
    }
    for (const k of new Set([...Object.keys(c.rows), ...Object.keys(s.rows)])) {
      if (c.rows[k] !== s.rows[k]) out.push(`reads.schedules.${name}.rows["${k}"]: committed ${c.rows[k]}, measured ${s.rows[k]}`);
    }
  }
  return out;
}
