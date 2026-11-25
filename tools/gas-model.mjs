// SPDX-License-Identifier: MIT
// gas/model.json: a per-action gas model for the SDK's write planner, so a large write can be split into
// publications without one eth_estimateGas round trip per guess (eth_estimateGas stays the authority before sending).
// It runs test/integration/GasModel.t.sol with `--json -vv` under the default profile (prague, the release bytes,
// out/) and the `amsterdam` profile (EIP-8037/8038, its own out/amsterdam + cache/amsterdam so the identity build in
// out/ is never touched), reads the "model <key> frame gas" lines (and "frame state gas" under amsterdam), fits
//
//   gas(publication) = fixed + Σ cost(action)
//   cost(PUBLISH new, shape S, body n bytes) = base[S] + perWord·ceil(n/32) + perByte·n
//   cost(PUBLISH existing), cost(REUSE), cost(CREATE), cost(BIND fresh|rebind, purpose), cost(UNBIND|RELEASE, purpose),
//   cost(WITHDRAW), plus firstWriteSurcharge once for a principal that has never written
//
// and predicts the suite's validation composites (never fitted). Exit 1 when a prague validation error exceeds 15%.
//
// `--check 1` (`pnpm gas:model:check`, CI) writes nothing: it re-measures, refits and exits 1 when a checked profile's
// validation error exceeds 15% or when its fitted constants or measured rows differ from the committed gas/model.json
// (gas is deterministic for identical bytecode, so the comparison is exact). `--skip-amsterdam 1` checks prague only.
//
//   node tools/gas-model.mjs [--skip-amsterdam 1] [--check 1]
import assert from "node:assert/strict";
import { execFileSync, spawnSync } from "node:child_process";
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { parseArgs, root, toJSON, validate } from "./deploy-plan.mjs";

const o = parseArgs(process.argv.slice(2), ["skip-amsterdam", "check"]);
const CHECK = !!o.check && o.check !== "0";
const SUITE = "test/integration/GasModel.t.sol";
const LIMIT_PERCENT = 15;
const git = (...args) => { try { return execFileSync("git", args, { cwd: root }).toString().trim(); } catch { return null; } };

function run(profile) {
  const env = { ...process.env, FOUNDRY_PROFILE: profile };
  if (profile !== "default") Object.assign(env, { FOUNDRY_OUT: `out/${profile}`, FOUNDRY_CACHE_PATH: `cache/${profile}` });
  const r = spawnSync("perl", ["-e", "alarm 900; exec @ARGV", "forge", "test", "--match-path", SUITE, "--json", "-vv"], { cwd: root, env, encoding: "utf8", timeout: 900_000, maxBuffer: 256 << 20 });
  const start = r.stdout.indexOf("{");
  assert.ok(start >= 0, `forge test (${profile}) printed no JSON (exit ${r.status}): ${r.stderr.slice(-3000)}`);
  const json = JSON.parse(r.stdout.slice(start));
  const rows = {};
  for (const result of Object.values(json)) {
    for (const [test, res] of Object.entries(result.test_results)) {
      assert.equal(res.status, "Success", `${profile}: ${test} ${res.status} ${res.reason ?? ""}`);
      for (const line of res.decoded_logs ?? []) {
        const m = line.match(/^model (.*?) (frame state gas|frame gas|gas): (-?\d+)$/);
        if (!m) continue;
        rows[m[1]] ??= { key: m[1], test };
        rows[m[1]][{ gas: "gas", "frame gas": "frameGas", "frame state gas": "frameStateGas" }[m[2]]] = Number(m[3]);
      }
    }
  }
  return Object.values(rows).sort((a, b) => a.key.localeCompare(b.key));
}

const words = (n) => Math.ceil(n / 32);

// The PUBLISH shapes the suite measures with their body length in bytes (GasModel.t.sol; the record bodies of
// src/lib/EfsFiles.sol). Bytes sizes fit the slopes; every other shape gets its own base.
const BYTES_SIZES = [64, 100, 1000, 1024, 4096, 8192];
const SHAPES = {
  "files-span/1": [["pub span", 96]],
  "files-content/1 carrier 0": [["pub content c0", 320]],
  "files-content/1 carrier 2": [["pub content c2", 320]],
  "files-external/1": [["pub external 40", 264], ["pub external 400", 624]],
  "files-directory/1": [["pub directory", 64]],
  "files-name/2": [["pub name 12", 12], ["pub name 200", 200]],
  "files-root/1 form 0": [["pub root f0", 164]],
  "files-root/1 form 1": [["pub root f1", 96]],
  "files-child/1 form 0": [["pub child f0", 196]],
  "files-child/1 form 1": [["pub child f1", 128]],
};
const ACTIONS = {
  publishExisting: "pub existing",
  reuse: "reuse",
  create: "create",
  bindHeadFresh: "bind head fresh",
  bindHeadRebind: "bind head rebind",
  bindFolderFreshFile: "bind folder fresh file",
  bindFolderFreshDirectory: "bind folder fresh dir",
  bindFolderRebind: "bind folder rebind",
  unbindFolder: "unbind folder",
  releaseFolder: "release folder",
  withdraw: "withdraw",
};

// The composites (GasModel.t.sol `test_model_validate_*`), as the planner would describe them.
const pub = (shape, n) => ({ publish: shape, n });
const VALIDATION = [
  { key: "validate create file", what: "M1 create file: CREATE, PUBLISH root form 0 (18-byte document), PUBLISH name (10 B), BIND HEAD, BIND FOLDER (first entry of a folder)",
    actions: ["create", pub("files-root/1 form 0", 82), pub("files-name/2", 10), "bindHeadFresh", "bindFolderFreshFile"] },
  { key: "validate edit", what: "edit: PUBLISH child form 0 (18-byte document), BIND HEAD rebind",
    actions: [pub("files-child/1 form 0", 114), "bindHeadRebind"] },
  { key: "validate rename move", what: "rename + move: PUBLISH name (9 B), UNBIND FOLDER, BIND FOLDER fresh (another folder)",
    actions: [pub("files-name/2", 9), "unbindFolder", "bindFolderFreshFile"] },
  { key: "validate two chunks", what: "two 8,192-byte files-bytes/1 records (16,384 body bytes, the publication cap)",
    actions: [pub("files-bytes/1", 8192), pub("files-bytes/1", 8192)] },
  { key: "validate 40kb last publication", what: "last publication of a 40,000-byte file: chunk 4 (7,392 B), four spans, files-content/1 carrier 2, CREATE, root form 1, name (7 B), BIND HEAD, BIND FOLDER",
    actions: [pub("files-bytes/1", 7392), pub("files-span/1", 96), pub("files-span/1", 96), pub("files-span/1", 96), pub("files-span/1", 96), pub("files-content/1 carrier 2", 320), "create", pub("files-root/1 form 1", 96), pub("files-name/2", 7), "bindHeadFresh", "bindFolderFreshFile"] },
];

/** Least squares y = X·β (normal equations, Gaussian elimination; tiny systems). */
function lsq(X, y) {
  const k = X[0].length;
  const A = Array.from({ length: k }, (_, i) => Array.from({ length: k + 1 }, (_, j) => (j < k ? X.reduce((s, r) => s + r[i] * r[j], 0) : X.reduce((s, r, t) => s + r[i] * y[t], 0))));
  for (let c = 0; c < k; c++) {
    let p = c;
    for (let r = c + 1; r < k; r++) if (Math.abs(A[r][c]) > Math.abs(A[p][c])) p = r;
    [A[c], A[p]] = [A[p], A[c]];
    for (let r = 0; r < k; r++) {
      if (r === c) continue;
      const f = A[r][c] / A[c][c];
      for (let j = c; j <= k; j++) A[r][j] -= f * A[c][j];
    }
  }
  return A.map((r, i) => r[k] / r[i]);
}
const median = (xs) => { const s = [...xs].sort((a, b) => a - b); const m = s.length >> 1; return s.length % 2 ? s[m] : (s[m - 1] + s[m]) / 2; };
const round = (x) => Math.round(x);

/** Constants from one measured quantity per row (`q(row)`: prague frame gas, amsterdam total / execution / state). */
function fit(rows, q) {
  const by = Object.fromEntries(rows.map((r) => [r.key, r]));
  const get = (k) => { assert.ok(by[k], `no "model ${k}" measurement`); return q(by[k]); };
  const marginal = (key) => get(`${key} k2`) - get(`${key} k1`);
  const impliedFixed = (key) => 2 * get(`${key} k1`) - get(`${key} k2`);
  // slopes and the files-bytes/1 base from the bytes sizes
  const bytesKeys = BYTES_SIZES.map((n) => `pub bytes ${n}`);
  const [bytesBase, perWord, perByte] = lsq(BYTES_SIZES.map((n) => [1, words(n), n]), bytesKeys.map(marginal));
  const body = (n) => perWord * words(n) + perByte * n;
  const publishBase = { "files-bytes/1": bytesBase };
  const publishBaseBySize = {};
  for (const [shape, sizes] of Object.entries(SHAPES)) {
    const each = sizes.map(([key, n]) => marginal(key) - body(n));
    publishBase[shape] = each.reduce((s, x) => s + x, 0) / each.length;
    if (sizes.length > 1) publishBaseBySize[shape] = Object.fromEntries(sizes.map(([, n], i) => [n, round(each[i])]));
  }
  const action = Object.fromEntries(Object.entries(ACTIONS).map(([name, key]) => [name, marginal(key)]));
  // the fixed cost: the median over every k1/k2 pair of 2·k1 − k2 (the per-pair values are kept in the rows)
  const pairs = [...bytesKeys, ...Object.values(SHAPES).flat().map(([k]) => k), ...Object.values(ACTIONS)];
  const fixedByPair = Object.fromEntries(pairs.map((k) => [k, impliedFixed(k)]));
  const fixed = median(Object.values(fixedByPair));
  const firstWriteSurcharge = get("first write fresh") - get("first write warm");
  return { fixed, perWord, perByte, publishBase, action, firstWriteSurcharge, publishBaseBySize, fixedByPair };
}

function predict(c, actions) {
  let g = c.fixed;
  for (const a of actions) {
    if (typeof a === "string") g += c.action[a];
    else g += c.publishBase[a.publish] + c.perWord * words(a.n) + c.perByte * a.n;
  }
  return g;
}

const rounded = (c) => ({
  fixed: round(c.fixed),
  perWord: round(c.perWord),
  perByte: Number(c.perByte.toFixed(1)),
  publishNew: Object.fromEntries(Object.entries(c.publishBase).map(([k, v]) => [k, round(v)])),
  ...Object.fromEntries(Object.entries(c.action).map(([k, v]) => [k, round(v)])),
  firstWriteSurcharge: round(c.firstWriteSurcharge),
});

function profile(rows, name) {
  const amsterdam = name === "amsterdam";
  const total = (r) => r.frameGas + (r.frameStateGas ?? 0);
  const c = fit(rows, total);
  const out = { quantity: amsterdam ? "frame gas + frame state gas (EIP-8037 execution + state)" : "frame gas", constants: rounded(c) };
  let ex = null;
  let st = null;
  if (amsterdam) {
    // every constant is a linear combination of measurements, so the split is the same fit on each part
    ex = fit(rows, (r) => r.frameGas);
    st = fit(rows, (r) => r.frameStateGas ?? 0);
    out.split = { executionGas: rounded(ex), stateGas: rounded(st), note: "constants = executionGas + stateGas (up to rounding); the EIP-7825 per-transaction cap (2^24) counts executionGas only" };
  }
  out.fit = {
    publishNewBaseBySize: Object.fromEntries(Object.entries(c.publishBaseBySize)),
    impliedFixedByPair: Object.fromEntries(Object.entries(c.fixedByPair).map(([k, v]) => [k, round(v)])),
    bytesResiduals: Object.fromEntries(BYTES_SIZES.map((n) => {
      const by = Object.fromEntries(rows.map((r) => [r.key, r]));
      const m = total(by[`pub bytes ${n} k2`]) - total(by[`pub bytes ${n} k1`]);
      return [n, round(m - (c.publishBase["files-bytes/1"] + c.perWord * words(n) + c.perByte * n))];
    })),
  };
  out.rows = rows;
  const by = Object.fromEntries(rows.map((r) => [r.key, r]));
  out.validation = VALIDATION.map((v) => {
    const m = by[v.key];
    assert.ok(m, `no "model ${v.key}" measurement`);
    const measured = total(m);
    const predicted = round(predict(c, v.actions));
    const row = { key: v.key, what: v.what, measured, predicted, errorPercent: Number((((predicted - measured) / measured) * 100).toFixed(2)) };
    if (amsterdam) {
      row.measuredExecutionGas = m.frameGas;
      row.predictedExecutionGas = round(predict(ex, v.actions));
      row.measuredStateGas = m.frameStateGas ?? 0;
      row.predictedStateGas = round(predict(st, v.actions));
    }
    return row;
  });
  out.maxAbsErrorPercent = Math.max(...out.validation.map((v) => Math.abs(v.errorPercent)));
  return out;
}

const prague = profile(run("default"), "prague");
const amsterdam = o["skip-amsterdam"] ? null : profile(run("amsterdam"), "amsterdam");

const model = {
  schema: "efs-gas-model/1",
  note: "Planning only: predicts the gas of one native-lane ILedger.execute publication from its actions, so the SDK can split a large write into publications without an eth_estimateGas round trip per guess. eth_estimateGas stays the authority before sending. Excluded: the 21,000 intrinsic cost and calldata (EIP-2028/7623; computable from the encoded transaction), refunds (EIP-3529; not applied, so the model errs high on clears), the signed lane, guards and STAGE/COMMIT.",
  method: {
    suite: SUITE,
    prague: "FOUNDRY_PROFILE=default (evm prague, the release bytes)",
    amsterdam: amsterdam ? "FOUNDRY_PROFILE=amsterdam FOUNDRY_OUT=out/amsterdam FOUNDRY_CACHE_PATH=cache/amsterdam (solc experimental amsterdam target; never release bytes)" : "skipped",
    measurement: "vm.lastFrameGas() of the execute call frame (gasTotalUsed, and gasStateUsed under amsterdam); every account the setUp touched is cooled (vm.cool) before each measured execute, so each publication pays the cold costs of a transaction of its own; the principal has written before except in the first-write pair",
    marginal: "cost of one action = gas(k = 2) − gas(k = 1) of two publications of the same shape with distinct bodies",
    slopes: `perWord and perByte: least squares of the files-bytes/1 marginal over body sizes ${BYTES_SIZES.join(", ")} (100 and 1,000 are not word multiples, which separates the two terms); publishNew[shape] = its marginal − perWord·ceil(n/32) − perByte·n, averaged over the measured sizes (fit.publishNewBaseBySize)`,
    fixed: "median of 2·gas(k = 1) − gas(k = 2) over every pair (fit.impliedFixedByPair: the first action of a kind in a publication pays some cold state that later ones find warm, which this single constant averages)",
    firstWriteSurcharge: "(CREATE + PUBLISH files-directory/1 as a principal's first publication ever) − (the same shape by a principal that has written once)",
    keys: "PUBLISH new: publishNew[shape] + perWord·ceil(n/32) + perByte·n, n = body bytes; FOLDER binds run FilesFinalValidator; rebind = CAS to a new target; UNBIND/RELEASE from BOUND; WITHDRAW of one occurrence",
  },
  profiles: { prague, ...(amsterdam ? { amsterdam } : {}) },
  source: { test: SUITE, commit: git("rev-parse", "HEAD"), dirtyFiles: (git("status", "--porcelain") || "").split("\n").filter(Boolean).length, date: new Date().toISOString(), foundry: execFileSync("forge", ["--version"]).toString().split("\n")[0].trim() },
};
const errs = validate(JSON.parse(toJSON(model)), "efs-gas-model-1.schema.json");
assert.deepEqual(errs, [], `gas/model.json does not match its schema:\n${errs.join("\n")}`);
if (CHECK) process.exit(check(JSON.parse(readFileSync(join(root, "gas/model.json"), "utf8"))));
mkdirSync(join(root, "gas"), { recursive: true });
writeFileSync(join(root, "gas/model.json"), toJSON(model));

console.log(`gas-model: gas/model.json (prague${amsterdam ? " + amsterdam" : ""})`);
for (const [name, p] of Object.entries(model.profiles)) {
  console.log(`  ${name}: ${JSON.stringify(p.constants)}`);
  for (const v of p.validation) console.log(`    ${v.key.padEnd(32)} measured ${String(v.measured).padStart(10)} predicted ${String(v.predicted).padStart(10)} ${v.errorPercent.toFixed(2).padStart(7)}%`);
  console.log(`    max |error| ${p.maxAbsErrorPercent}%`);
}
const bad = prague.validation.filter((v) => Math.abs(v.errorPercent) > LIMIT_PERCENT);
if (bad.length) {
  for (const v of bad) console.error(`gas-model: prague "${v.key}" predicted ${v.predicted}, measured ${v.measured}: ${v.errorPercent}% exceeds ±${LIMIT_PERCENT}%`);
  process.exit(1);
}

/** Paths at which `a` and `b` (parsed JSON) differ, each with both values. */
function diff(a, b, path, out) {
  if (a === b) return out;
  if (a && b && typeof a === "object" && typeof b === "object" && Array.isArray(a) === Array.isArray(b)) {
    for (const k of new Set([...Object.keys(a), ...Object.keys(b)])) diff(a[k], b[k], `${path}${Array.isArray(a) ? `[${k}]` : `.${k}`}`, out);
    return out;
  }
  out.push(`${path}: committed ${JSON.stringify(a)}, measured ${JSON.stringify(b)}`);
  return out;
}

/** --check: the error bound, and exact equality of the fitted constants and the measured rows, per checked profile. */
function check(committed) {
  const fresh = JSON.parse(toJSON(model));
  const bound = [];
  const differences = [];
  for (const [name, p] of Object.entries(fresh.profiles)) {
    for (const v of p.validation) {
      if (Math.abs(v.errorPercent) > LIMIT_PERCENT) bound.push(`${name} "${v.key}" predicted ${v.predicted}, measured ${v.measured}: ${v.errorPercent}% exceeds ±${LIMIT_PERCENT}%`);
    }
    const c = committed.profiles?.[name];
    if (!c) { differences.push(`profiles.${name}: absent from the committed gas/model.json`); continue; }
    for (const k of ["constants", "split", "rows"]) diff(c[k], p[k], `profiles.${name}.${k}`, differences);
  }
  for (const m of bound) console.error(`gas-model --check: ${m}`);
  if (differences.length) {
    const shown = Math.min(8, differences.length);
    console.error(`gas-model --check: gas/model.json is stale (${Object.keys(fresh.profiles).join(" + ")}): ${differences.length} difference(s), the first ${shown}:`);
    for (const d of differences.slice(0, shown)) console.error(`  ${d}`);
    console.error("gas-model --check: regenerate with `pnpm run gas:model`, then `pnpm run release`");
  }
  if (bound.length || differences.length) return 1;
  const checked = Object.entries(fresh.profiles).map(([n, p]) => `${n} (${p.rows.length} rows, max |error| ${p.maxAbsErrorPercent}%)`).join(", ");
  console.log(`gas-model --check: OK, the committed gas/model.json equals the measurement: ${checked}`);
  return 0;
}
