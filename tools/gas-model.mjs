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
//   cost(BIND TAG number change) (a REBIND to the same target with a new strength), cost(UNBIND TAG lone) (a first mask),
//   cost(BIND PROPERTY fresh|rebind), cost(BIND SAME fresh word|path), cost(BIND BROADER fresh), cost(UNBIND|RELEASE,
//   PROPERTY|SAME|BROADER), cost(restore SAME|BROADER), cost(WITHDRAW), plus firstWriteSurcharge once for a principal
//   that has never written
//   cost(first TAG on an n-word topic) = bindTagFresh | bindTagSecondAuthor (fresh | existing position)
//     + Σ over the n − 1 proper ancestors: tagLevel.mine{New|Existing}
//       + (fresh position or a first yes ? tagLevel.shared{New|Existing} : 0)
//
// and predicts the suite's validation composites (never fitted). Exit 1 when a prague validation error exceeds 15%.
//
// The floor (design §10.4). Every measured publication is also run with the index's callbacks answered by
// `vm.mockCall` ("model <key> kernel frame gas"); the same fit of those rows is `floor.<schedule>.kernel`, the kernel's
// own execution gas. `floor` also carries the kernel's quote inputs exactly (the work model and the Realm's floor
// prices from tools/deploy-plan.mjs, the per-Type refs and digest specs the suite logs, the 63/64 rule and the
// dispatch overhead) and `planning` the rule a planner sizes a publication by (tools/gas-plan.mjs implements it).
// `ILedgerCommitments.indexFloor` prices every bind as a first statement and is an upper bound on the prefix floor only:
// a consumer plans from the model's rule.
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
import { GLAMSTERDAM_FLOOR, LIMITS, WORK_MODEL, parseArgs, root, toJSON, validate } from "./deploy-plan.mjs";
import { FIXED_ANCHORS, fixedFrom } from "./gas-fit.mjs";

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
  const types = {};
  for (const result of Object.values(json)) {
    for (const [test, res] of Object.entries(result.test_results)) {
      assert.equal(res.status, "Success", `${profile}: ${test} ${res.status} ${res.reason ?? ""}`);
      for (const line of res.decoded_logs ?? []) {
        const t = line.match(/^model type (\S+) (refs|specs): (\d+)$/);
        if (t) {
          (types[t[1]] ??= {})[t[2]] = Number(t[3]);
          continue;
        }
        const m = line.match(/^model (.*?) (kernel frame gas|frame state gas|frame gas|gas): (-?\d+)$/);
        if (!m) continue;
        rows[m[1]] ??= { key: m[1], test };
        rows[m[1]][{ gas: "gas", "frame gas": "frameGas", "frame state gas": "frameStateGas", "kernel frame gas": "kernelFrameGas" }[m[2]]] = Number(m[3]);
      }
    }
  }
  assert.ok(Object.keys(types).length > 0, `${profile}: no "model type" lines (test_model_floor_types)`);
  return { rows: Object.values(rows).sort((a, b) => a.key.localeCompare(b.key)), types };
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
  "topic-word/1": [["pub topic word 12", 12], ["pub topic word 40", 40]],
  "topic/1": [["pub topic", 64]],
  "text/1": [["pub text 24", 24]],
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
  bindTagFresh: "bind tag fresh",
  bindTagSecondAuthor: "bind tag second author",
  bindTagNumberChange: "bind tag number change",
  unbindTagLone: "unbind tag lone",
  unbindTag: "unbind tag",
  releaseTag: "release tag",
  restoreTag: "restore tag",
  // statements about topics (design §12.5): PROPERTY (a label: labelKey("en") → an existing text/1), SAME (word page
  // to word page, or 2-word path to path) and BROADER (word page to word page); each first statement and its later
  // statements
  bindPropertyFresh: "bind property fresh",
  bindPropertyRebind: "bind property rebind",
  unbindProperty: "unbind property",
  releaseProperty: "release property",
  bindSameFreshWord: "bind same fresh word",
  bindSameFreshPath: "bind same fresh path",
  unbindSame: "unbind same",
  releaseSame: "release same",
  restoreSame: "restore same",
  bindBroaderFresh: "bind broader fresh",
  unbindBroader: "unbind broader",
  releaseBroader: "release broader",
  restoreBroader: "restore broader",
  withdraw: "withdraw",
};

// The per-level terms of a first tag (design §10.4): each row's k1 tags a 2-word topic and k2 a 6-word topic from the
// same state, so (k2 − k1) / LEVEL_SPAN is one level of the ancestor walk in that case.
const LEVEL_SPAN = 4;
const LEVEL_ROWS = { allNew: "tag level all new", allExisting: "tag level all existing", mineNew: "tag level mine new", mineExisting: "tag level mine existing" };

// The composites (GasModel.t.sol `test_model_validate_*`), as the planner would describe them.
const pub = (shape, n) => ({ publish: shape, n });
const levels = (level, n) => ({ level, n });
const VALIDATION = [
  { key: "validate create file", what: "M1 create file: CREATE, PUBLISH root form 0 (18-byte document), PUBLISH name (10 B), BIND HEAD, BIND FOLDER (first entry of a folder)",
    actions: ["create", pub("files-root/1 form 0", 82), pub("files-name/2", 10), "bindHeadFresh", "bindFolderFreshFile"] },
  { key: "validate edit", what: "edit: PUBLISH child form 0 (18-byte document), BIND HEAD rebind",
    actions: [pub("files-child/1 form 0", 114), "bindHeadRebind"] },
  { key: "validate rename move", what: "rename + move (EfsFiles.move): PUBLISH name (9 B), RELEASE FOLDER, BIND FOLDER fresh (another folder)",
    actions: [pub("files-name/2", 9), "releaseFolder", "bindFolderFreshFile"] },
  { key: "validate two chunks", what: "two 8,192-byte files-bytes/1 records (16,384 body bytes, the publication cap)",
    actions: [pub("files-bytes/1", 8192), pub("files-bytes/1", 8192)] },
  { key: "validate 40kb last publication", what: "last publication of a 40,000-byte file: chunk 4 (7,392 B), four spans, files-content/1 carrier 2, CREATE, root form 1, name (7 B), BIND HEAD, BIND FOLDER",
    actions: [pub("files-bytes/1", 7392), pub("files-span/1", 96), pub("files-span/1", 96), pub("files-span/1", 96), pub("files-span/1", 96), pub("files-content/1 carrier 2", 320), "create", pub("files-root/1 form 1", 96), pub("files-name/2", 7), "bindHeadFresh", "bindFolderFreshFile"] },
  { key: "validate tag 6 words all new", what: "a first tag on a fresh 6-word path: the fresh-position term plus five levels, every per-author and shared roll-up new",
    actions: ["bindTagFresh", levels("mineNew", 5), levels("sharedNew", 5)] },
  { key: "validate label new text", what: "a label with its text (EfsTopics.label): PUBLISH a new 24-byte text/1, BIND PROPERTY labelKey(\"en\") to it (a first statement)",
    actions: [pub("text/1", 24), "bindPropertyFresh"] },
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
  // the fixed cost: 2·k1 − k2 of every k1/k2 pair is kept (fit.impliedFixedByPair), and `fixed` is their median over
  // the anchor pairs only (tools/gas-fit.mjs), so a row added later never changes the price of an existing action
  const pairs = [...bytesKeys, ...Object.values(SHAPES).flat().map(([k]) => k), ...Object.values(ACTIONS)];
  const fixedByPair = Object.fromEntries(pairs.map((k) => [k, impliedFixed(k)]));
  const fixed = fixedFrom(fixedByPair);
  const firstWriteSurcharge = get("first write fresh") - get("first write warm");
  const level = Object.fromEntries(Object.entries(LEVEL_ROWS).map(([k, key]) => [k, marginal(key) / LEVEL_SPAN]));
  const tagLevel = { mineNew: level.mineNew, mineExisting: level.mineExisting, sharedNew: level.allNew - level.mineNew, sharedExisting: level.allExisting - level.mineExisting };
  return { fixed, perWord, perByte, publishBase, action, firstWriteSurcharge, tagLevel, publishBaseBySize, fixedByPair };
}

function predict(c, actions) {
  let g = c.fixed;
  for (const a of actions) {
    if (typeof a === "string") g += c.action[a];
    else if (a.level) g += c.tagLevel[a.level] * a.n;
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
  tagLevel: Object.fromEntries(Object.entries(c.tagLevel).map(([k, v]) => [k, round(v)])),
});

/** The kernel's quote inputs exactly as the Realm of this schedule activates them (design §10.4). */
const FLOOR_LIMITS = {
  prague: { floorFreshGas: LIMITS.floorFreshGas, floorRewriteGas: LIMITS.floorRewriteGas, kernelTail: LIMITS.kernelTail },
  amsterdam: GLAMSTERDAM_FLOOR,
};
/** An upper bound on the gas the ingress's dispatchIndex spends before its own 63/64 check (the whole dispatch,
 *  calldata decode, encoding, CALL and acknowledgement, is 1,947 on both schedules in the -vvvv traces). */
const DISPATCH_OVERHEAD = 2000;

const FLOOR_FORMULA = [
  "The kernel's quote (LedgerIngress._foldAndQuote, work-model formula 2) over a publication of n actions: fresh10 = workModel.freshPerPublication + Σ over PUBLISH/REUSE (freshPerRef·types[T].refs, plus freshPerPublishFresh + freshPerDigestSpec·types[T].specs when the record is new, or freshPerPublishExisting when it exists: a repeat PUBLISH or any REUSE) + Σ over first statements (freshPerBindFresh); rw10 = rwPerPublication + rwPerPublish per PUBLISH/REUSE + Σ over BIND/UNBIND/RELEASE (rwPerBind, plus rwPerBindLater for a later statement); a first statement is a BIND or UNBIND whose author's head at the position is UNSET, every other bind-kind action (a RELEASE always) is a later statement; freshSlots = ceil(fresh10 / 10), rewrites = ceil(rw10 / 10);",
  "prefixFloor P = computeBase + n·computePerAction + binds·computePerHookEffect + freshSlots·limits.floorFreshGas + rewrites·limits.floorRewriteGas (binds = the BIND/UNBIND/RELEASE count); finalReserve F = finalComputeBase + binds·finalComputePerBind + publishes·finalComputePerPublish (publishes = the PUBLISH/REUSE count).",
  "The checks (design §6.4, §6.5): before callback i the kernel requires its gasleft g > F + T and forwards (g − F − T)·63/64 to the ingress, which spends at most dispatchOverhead, then requires (its gasleft)·63/64 ≥ R_i = max(0, P − the callbacks' spend so far) (E_INDEX_GAS otherwise); before the final phase it requires (g − T)·63/64 ≥ F. T = limits.kernelTail.",
  "Sufficient visible execution gas (G = the gas limit less intrinsic gas and calldata): G ≥ V = max(K + ceil((ceil(P·64/63) + dispatchOverhead)·64/63), E) + ceil(F·64/63) + T, where E is the publication's execution gas and K the kernel's own share of it (callbacks excluded): at callback i the gas spent so far is at most K plus the callbacks' spend s, and R_i·(64/63)² ≥ P·(64/63)² − s, so the kernel's spend and the floor never need more than K + P·(64/63)²; the final check needs at most E + F·64/63 + T.",
  "A planner uses the model's execution estimate for E (prague: constants; amsterdam: split.executionGas) and floor.kernel (the same model fitted with the callbacks removed) for K.",
  "ILedgerCommitments.indexFloor quotes without a principal, so it prices every BIND and UNBIND as a first statement: it is an upper bound on P only (exact when every bind-kind action is a first statement), and a consumer plans from this rule, never from indexFloor.",
].join(" ");

function floorOf(rows, name, types) {
  const kernel = fit(rows, (r) => {
    assert.ok(Number.isInteger(r.kernelFrameGas), `${name}: no "model ${r.key} kernel frame gas" measurement`);
    return r.kernelFrameGas;
  });
  return {
    formula: FLOOR_FORMULA,
    quantity: "execution gas visible to the GAS opcode (on amsterdam the EIP-8037 state-gas reservoir is not visible and the cap counts execution gas only)",
    workModel: WORK_MODEL,
    limits: FLOOR_LIMITS[name],
    callGasRetained: { numerator: 63, denominator: 64 },
    dispatchOverhead: DISPATCH_OVERHEAD,
    types: Object.fromEntries(Object.entries(types).sort(([a], [b]) => a.localeCompare(b))),
    kernel: rounded(kernel),
    _kernel: kernel,
  };
}

function profile({ rows, types }, name) {
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
    fixedAnchors: [...FIXED_ANCHORS],
    publishNewBaseBySize: Object.fromEntries(Object.entries(c.publishBaseBySize)),
    impliedFixedByPair: Object.fromEntries(Object.entries(c.fixedByPair).map(([k, v]) => [k, round(v)])),
    bytesResiduals: Object.fromEntries(BYTES_SIZES.map((n) => {
      const by = Object.fromEntries(rows.map((r) => [r.key, r]));
      const m = total(by[`pub bytes ${n} k2`]) - total(by[`pub bytes ${n} k1`]);
      return [n, round(m - (c.publishBase["files-bytes/1"] + c.perWord * words(n) + c.perByte * n))];
    })),
  };
  const floor = floorOf(rows, name, types);
  const kernelFit = floor._kernel;
  delete floor._kernel;
  out.floor = floor;
  out.rows = rows;
  const by = Object.fromEntries(rows.map((r) => [r.key, r]));
  out.validation = VALIDATION.map((v) => {
    const m = by[v.key];
    assert.ok(m, `no "model ${v.key}" measurement`);
    const measured = total(m);
    const predicted = round(predict(c, v.actions));
    const row = { key: v.key, what: v.what, measured, predicted, errorPercent: Number((((predicted - measured) / measured) * 100).toFixed(2)), measuredKernelGas: m.kernelFrameGas, predictedKernelGas: round(predict(kernelFit, v.actions)) };
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

const TAG_LEVELS_METHOD = `a first TAG statement (either sign) on an n-word topic = bindTagFresh (no author has stated anything at the position) or bindTagSecondAuthor (the position exists; measured as a first yes, which files one place entry, so it is an upper bound for a first no there) + Σ over its n − 1 proper ancestors of tagLevel.mineNew | mineExisting (the author's scope-below list at that ancestor is empty | not) + (a fresh position, either sign, or a first yes at an existing position: every filing) tagLevel.sharedNew | sharedExisting (the place-below list at that ancestor is empty | not); a list with exactly 1 entry or a multiple of 5 takes a fresh word on its next append, so price it as new (tagLists.priceAsNew). Measured: (k2 − k1) / ${LEVEL_SPAN} of a first statement on a 2-word and on a 6-word topic from the same state (rows "tag level all new | all existing": a first tag at a fresh position; "mine new | mine existing": a first no at an existing position, which files nothing below); shared = all − mine`;
/** The planning rule (tools/gas-plan.mjs implements it; tools/release.mjs reads txGasCap and headroomPercent from here). */
const PLANNING = {
  rule: "A publication is planned when it is inside limits (1 ≤ actions ≤ maxActions, bind-kind actions ≤ maxBindsPerPublication, PUBLISH body bytes ≤ maxBodyBytesPerPublication) and max(E, V) ≤ floor(txGasCap × (100 − headroomPercent) / 100), on the schedule of the chain: E the model's execution estimate (prague: constants; amsterdam: split.executionGas), V the floor's visible-gas requirement (profiles.<schedule>.floor.formula). A shape that does not fit is split into publications before it is signed, never shortened; eth_estimateGas on the exact call stays the authority before sending, and the gas limit comes from the estimate, never from V.",
  txGasCap: 16777216,
  txGasCapRule: "EIP-7825 (on amsterdam, EIP-8037: the cap counts execution gas only)",
  headroomPercent: 15,
  headroomCovers: "the 21,000 intrinsic cost, calldata (EIP-2028/7623) and the model's own error (under 9% on both schedules, maxAbsErrorPercent)",
  limits: { maxActions: LIMITS.maxActions, maxBindsPerPublication: LIMITS.maxBindsPerPublication, maxBodyBytesPerPublication: LIMITS.maxBodyBytesPerPublication },
};
/** Read by the planner with the tagLevel terms (design §10.4). */
const TAG_LISTS = {
  priceAsNew: { entries: [1], entriesMultipleOf: 5 },
  note: "A per-author (scope-below) or shared (place-below) roll-up list holding exactly one entry, or a multiple of five entries (zero included: an empty list), takes a fresh word on its next append, so price that append as new (tagLevel.mineNew or sharedNew); otherwise as existing. The fresh word costs one slot rewrite more than a new list, inside the headroom; not separately measured.",
};

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
    fixed: "median of 2·gas(k = 1) − gas(k = 2) over the anchor pairs only (fit.fixedAnchors: the pairs the model had at 899767e, frozen in tools/gas-fit.mjs), so a row added later never changes the price of an existing action; fit.impliedFixedByPair keeps the value of every pair, anchors or not (the first action of a kind in a publication pays some cold state that later ones find warm, which this single constant averages)",
    firstWriteSurcharge: "(CREATE + PUBLISH files-directory/1 as a principal's first publication ever) − (the same shape by a principal that has written once)",
    keys: "PUBLISH new: publishNew[shape] + perWord·ceil(n/32) + perByte·n, n = body bytes; FOLDER binds run FilesFinalValidator; rebind = CAS to a new target; UNBIND/RELEASE from BOUND; restore = BIND from MASKED to the kept target; PROPERTY binds are a label (labelKey(\"en\") on a word page → an existing text/1; a label with a new text is publishNew[\"text/1\"] + its body terms + bindPropertyFresh, validated by \"validate label new text\"); SAME and BROADER first statements run FilesFinalValidator's topic checks on subject and role (word page to word page; bindSameFreshPath 2-word path to path), their later statements are on word pages; WITHDRAW of one occurrence",
    tagLevels: TAG_LEVELS_METHOD,
  },
  planning: PLANNING,
  tagLists: TAG_LISTS,
  profiles: { prague, ...(amsterdam ? { amsterdam } : {}) },
  source: { test: SUITE, commit: git("rev-parse", "HEAD"), dirtyFiles: (git("status", "--porcelain") || "").split("\n").filter(Boolean).length, date: new Date().toISOString(), foundry: execFileSync("forge", ["--version"]).toString().split("\n")[0].trim() },
};
// the topic readers' read terms and call bounds (tools/gas-reads.mjs; a section of its own beside the profiles)
const { measureReads, checkReads } = await import("./gas-reads.mjs");
model.reads = measureReads({ amsterdam: !o["skip-amsterdam"] });
const errs = validate(JSON.parse(toJSON(model)), "efs-gas-model-1.schema.json");
assert.deepEqual(errs, [], `gas/model.json does not match its schema:\n${errs.join("\n")}`);
if (CHECK) {
  const committed = JSON.parse(readFileSync(join(root, "gas/model.json"), "utf8"));
  const stale = checkReads(committed.reads, JSON.parse(toJSON(model.reads)));
  for (const d of stale.slice(0, 8)) console.error(`gas-model --check: ${d}`);
  if (!stale.length) console.log(`gas-model --check: OK, the committed reads rows equal the measurement (${Object.keys(model.reads.schedules).join(" + ")})`);
  process.exit(check(committed) | (stale.length ? 1 : 0));
}
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
    for (const k of ["constants", "split", "floor", "rows"]) diff(c[k], p[k], `profiles.${name}.${k}`, differences);
  }
  for (const k of ["planning", "tagLists"]) diff(committed[k], fresh[k], k, differences);
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
