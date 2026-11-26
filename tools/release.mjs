// SPDX-License-Identifier: MIT
// The release manifest of design §13 (`efs-contracts-release/1`), generated from the identity build in out/, the
// auxiliary AST build in out/release-ast (immutable names; its bytecode must equal out/'s, the double-build check)
// and the chain-free plan facts of tools/deploy-plan.mjs. It also writes release/errors.json (the error catalog),
// artifacts/<Unit>.json (ABI union, bytecode, immutables, method identifiers), test/vectors/media.json (the
// media-type vectors of tools/media-vectors.mjs for the release Type ids), test/vectors/numbers.json (the binding
// number vectors of tools/number-vectors.mjs), test/vectors/topics.json (the Topics vectors of
// tools/topic-vectors.mjs) and test/vectors/names.json (the file name vectors of tools/name-vectors.mjs) and cross-checks the JS Files and Topics twin against the Solidity FilesTypes and
// TopicTypes through `forge script script/Genesis.s.sol --sig "profile(address)"`.
//
//   node tools/release.mjs [--skip-script 1] [--check 1]
//
// `--check 1` writes nothing: it regenerates every document in memory and fails when a committed file differs
// (release/errors.json, artifacts/*.json, test/vectors/media.json, test/vectors/numbers.json, test/vectors/topics.json, test/vectors/names.json and deploy/plan.json byte for byte; release/release.json without the facts
// of the machine and the moment: source commit, forge and node versions, build platform, the double-build count and
// the script cross-check record). CI runs it after the suites, so a push whose snapshot is stale against its own
// sources cannot merge. Without an AST build (CI) the immutable names are the manifest's and their offsets are checked
// against the build; the fixture's verify then reads every named immutable from the chain.
//
// Digest = sha256(release/release.json); the fixture copies it into efs-deployment/1.
import assert from "node:assert/strict";
import { execFileSync, spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { existsSync, mkdirSync, readFileSync, readdirSync, writeFileSync } from "node:fs";
import { arch, platform, release as osRelease } from "node:os";
import { join, relative } from "node:path";
import { keccak256, toFunctionSelector } from "viem";
import { mediaVectors } from "./media-vectors.mjs";
import { numberVectors } from "./number-vectors.mjs";
import { topicVectors } from "./topic-vectors.mjs";
import { nameVectors } from "./name-vectors.mjs";
import { planVectors } from "./gas-plan.mjs";
import { ABI_IDS, idFromSnapshot } from "./abi-id.mjs";
import { ARTIFACTS_MODE, AST_OUT, GLAMSTERDAM_FLOOR, OUT, SOURCE_ROOT, UNITS, artifact, buildPlan, hasAst, immutableLayout, jsonable, parseArgs, planDocument, root, toJSON } from "./deploy-plan.mjs";

const o = parseArgs(process.argv.slice(2), ["skip-script", "check"]);
const CHECK = !!o.check && o.check !== "0";
/** Write a generated document, or (--check) compare it with the committed one. `stable` maps a parsed document to
 *  the part that must reproduce on any machine; without it the comparison is byte for byte. */
const drift = [];
const generated = new Map();
const emit = (rel, text, stable) => {
  generated.set(rel, text);
  if (!CHECK) return writeFileSync(join(root, rel), text);
  const path = join(root, rel);
  if (!existsSync(path)) return drift.push(`${rel}: missing`);
  const have = readFileSync(path, "utf8");
  if (!stable) { if (have !== text) drift.push(`${rel}: differs from the build`); return; }
  const [x, y] = [stable(JSON.parse(have)), stable(JSON.parse(text))];
  for (const k of new Set([...Object.keys(x), ...Object.keys(y)])) if (JSON.stringify(x[k]) !== JSON.stringify(y[k])) drift.push(`${rel}: "${k}" differs from the build`);
};
assert.equal(ARTIFACTS_MODE, "forge", `tools/release.mjs reads a Foundry build; ${OUT} is a ${ARTIFACTS_MODE} directory (unset EFS_ARTIFACTS_DIR)`);
const sha256 = (buf) => `0x${createHash("sha256").update(buf).digest("hex")}`;
const git = (...args) => { try { return execFileSync("git", args, { cwd: root }).toString().trim(); } catch { return null; } };

const plan = await buildPlan();
const sizes = JSON.parse(readFileSync(join(root, "test/snapshots/sizes.json"), "utf8"));
const budgetOf = (name) => sizes.units.find((u) => u.name === name) ?? null;

// ---- per-unit facts ------------------------------------------------------------------------------------------------
const stepOf = (name) => plan.steps.find((s) => s.kind === "CREATE2" && s.contract === name);
const createdOf = (label) => plan.steps.find((s) => s.id === "G18").creates.find((c) => c.label === label);
const realmSpecific = new Set(["RealmGenesis", "PostingStore", "BitmapStore", "IndexReads", "RealmIndex", "RealmController", "TransparentUpgradeableProxy", "ProxyAdmin", "LensReader", "FilesPageReader", "TopicMineReader", "TopicEveryoneReader", "TopicLookupReader", "EfsWeb3Content", "EfsWeb3Gateway"]);
const contracts = {};
let reproducible = 0;
for (const name of Object.keys(UNITS)) {
  const a = artifact(name);
  const imm = immutableLayout(name);
  if (hasAst(name)) reproducible++;
  const step = stepOf(name);
  const deployed = step ?? (name === "RealmController" ? createdOf("RealmController") : name === "ProxyAdmin" ? createdOf("LedgerProxyAdmin") : name === "TransparentUpgradeableProxy" ? createdOf("LedgerProxy") : null);
  const b = budgetOf(name);
  contracts[name] = {
    source: a.source,
    runtimeHash: keccak256(a.runtime), // the compiled runtime with every immutable slot zero
    deployedBytecodeHash: deployed?.runtimeCodehash ?? null, // with this release's immutables (plan step)
    initcodeHash: keccak256(a.bytecode),
    initcodeWithArgsHash: step?.initcodeHash ?? null,
    address: deployed?.address ?? null,
    realmSpecific: realmSpecific.has(name),
    planStep: step?.id ?? (deployed ? "G18" : null),
    immutables: imm,
    sizes: { runtime: (a.runtime.length - 2) / 2, initcode: (a.bytecode.length - 2) / 2, initcodeWithArgs: step?.initcodeBytes ?? null },
    budget: b ? { runtime: b.runtimeBudget, initcode: b.initcodeBudget } : null,
  };
  if (a.source.startsWith("src/profiles/")) assert.deepEqual(imm, [], `${name}: a profile contract must have no immutable references`);
}

// ---- the files the units were built from ---------------------------------------------------------------------------
const files = {};
for (const name of Object.keys(UNITS)) {
  const meta = JSON.parse(readFileSync(join(OUT, `${UNITS[name]}.sol`, `${name}.json`), "utf8")).metadata;
  for (const src of Object.keys(meta.sources)) files[src] ??= sha256(readFileSync(join(SOURCE_ROOT, src)));
}

// ---- the error catalog (design §5.6): file-level errors with the retry class in the trailing comment ----------------
const errors = {};
const walk = (dir) => readdirSync(join(root, dir), { withFileTypes: true }).flatMap((e) => (e.isDirectory() ? walk(`${dir}/${e.name}`) : e.name.endsWith(".sol") ? [`${dir}/${e.name}`] : []));
for (const path of walk("src").sort()) {
  let doc = [];
  for (const line of readFileSync(join(root, path), "utf8").split("\n")) {
    const d = line.match(/^\/\/\/\s?(.*)$/);
    if (d) { doc.push(d[1].trim()); continue; }
    const m = line.match(/^error\s+(\w+)\(([^)]*)\);\s*(?:\/\/\s*(.*))?$/);
    const above = doc.join(" ");
    doc = [];
    if (!m) continue;
    const params = m[2].trim() ? m[2].split(",").map((p) => p.trim().split(/\s+/)) : [];
    const sig = `${m[1]}(${params.map(([t]) => t.replace(/^uint$/, "uint256")).join(",")})`;
    const comment = (m[3] ?? "").trim();
    const cls = comment.match(/^(none|reprepare|resubmit|wait)\b/)?.[1] ?? null;
    assert.ok(cls, `${path}: error ${m[1]} has no retry class (the trailing comment starts with none, reprepare, resubmit or wait)`);
    errors[toFunctionSelector(sig)] = { name: m[1], signature: sig, args: params.map(([t, n]) => ({ type: t, name: n ?? "" })), source: path, retryClass: cls, meaning: comment.replace(/^(none|reprepare|resubmit|wait)\b[:\s]*/, "") || above || null };
  }
}
const snap = JSON.parse(readFileSync(join(root, "test/snapshots/abi/Errors.json"), "utf8")).errors;
for (const [sel, sig] of Object.entries(snap)) assert.equal(errors[sel]?.signature, sig, `error catalog: ${sig} (${sel}) from test/snapshots/abi/Errors.json not reproduced`);
if (!CHECK) mkdirSync(join(root, "release"), { recursive: true });
emit("release/errors.json", toJSON({ schema: "efs-errors/1", source: "src/**/*.sol file-level errors; retry class = the trailing comment's first word", errors: Object.fromEntries(Object.entries(errors).sort(([, x], [, y]) => (x.name < y.name ? -1 : 1))) }));

// ---- artifacts/: the deployable units' ABI (kernel = core ∪ apply ∪ ingress ∪ control fragments), bytecode, ids -----
if (!CHECK) mkdirSync(join(root, "artifacts"), { recursive: true });
const union = (names) => {
  const seen = new Map();
  for (const n of names) for (const item of artifact(n).abi) {
    const k = `${item.type} ${item.name ?? ""}(${(item.inputs ?? []).map((i) => i.type).join(",")})`;
    if (item.type === "constructor" && n !== names[0]) continue;
    if (!seen.has(k) && (n === names[0] || item.type === "event" || item.type === "error")) seen.set(k, item);
  }
  return [...seen.values()];
};
// RealmIndex answers every IIndexReads function at its address, the ones it does not implement through its fallback
// (forwarded to IndexReads by STATICCALL, design §10.1), so its artifact lists them too: callers see one ABI.
function withForwardedReads(abi, methodIdentifiers) {
  // the snapshot maps "0x<selector>" -> signature; solc's methodIdentifiers map signature -> "<selector>"
  const reads = JSON.parse(readFileSync(join(root, "test/snapshots/abi/IIndexReads.json"), "utf8"));
  const sigOf = (i) => `${i.name}(${(i.inputs ?? []).map((p) => p.type).join(",")})`;
  const ids = { ...methodIdentifiers };
  const extra = [];
  for (const item of reads.abi.filter((i) => i.type === "function")) {
    const sel = Object.entries(reads.methodIdentifiers).find(([, sig]) => sig === sigOf(item))?.[0];
    assert.ok(sel, `IIndexReads.${item.name}: no selector in the snapshot`);
    if (Object.values(methodIdentifiers).includes(sel.slice(2))) continue;
    extra.push(item);
    ids[sigOf(item)] = sel.slice(2);
  }
  return { abi: [...abi, ...extra], methodIdentifiers: Object.fromEntries(Object.entries(ids).sort(([x], [y]) => (x < y ? -1 : 1))) };
}
for (const name of Object.keys(UNITS)) {
  const a = artifact(name);
  const raw = JSON.parse(readFileSync(join(OUT, `${UNITS[name]}.sol`, `${name}.json`), "utf8"));
  let abi = name === "LedgerCore" ? union(["LedgerCore", "LedgerApply", "LedgerIngress", "LedgerControl"]) : a.abi;
  let methodIdentifiers = raw.methodIdentifiers;
  if (name === "RealmIndex") ({ abi, methodIdentifiers } = withForwardedReads(abi, methodIdentifiers));
  emit(`artifacts/${name}.json`, toJSON({ schema: "efs-artifact/1", name, source: a.source, abi, methodIdentifiers, bytecode: a.bytecode, deployedBytecode: a.runtime, immutables: contracts[name].immutables, storageLayout: "test/snapshots/layout/", interfaces: "test/snapshots/abi/" }));
}
// artifacts/index.json: what a deploy from artifacts/ alone needs besides the units (tools/deploy-plan.mjs "release" layout)
emit("artifacts/index.json", toJSON({ schema: "efs-artifacts-index/1", layoutId: plan.layoutId, hotAbiId: plan.hotAbiId, hotAbiIdString: plan.hotAbiIdString, units: Object.keys(UNITS), manifest: "release/release.json", note: "each <Unit>.json is efs-artifact/1; a fixture deploys from this directory with `efs-fixture up --artifacts artifacts [--plan deploy/plan.json]`" }));

// ---- test/vectors/media.json: media-type encodings and grammar verdicts for the release Type ids -------------------
emit("test/vectors/media.json", toJSON(mediaVectors(plan)));
// ---- test/vectors/numbers.json: the binding number's shape law, signed numbers and builder encodings ---------------
emit("test/vectors/numbers.json", toJSON(numberVectors()));
// ---- test/vectors/topics.json: the Topics grammars, refused code points, path ids, property keys and builders -----
emit("test/vectors/topics.json", toJSON(topicVectors(plan)));
// ---- test/vectors/names.json: the files-name/3 grammar's verdicts, roles and record ids -----------------------------
emit("test/vectors/names.json", toJSON(nameVectors(plan)));

// ---- cross-check: the JS Files twin against the Solidity FilesTypes ------------------------------------------------
let scriptCheck = { ran: false };
if (!o["skip-script"]) {
  const r = spawnSync("perl", ["-e", "alarm 900; exec @ARGV", "forge", "script", "script/Genesis.s.sol", "--sig", "profile(address)", plan.owner, "--json"], { cwd: root, encoding: "utf8", timeout: 900_000, maxBuffer: 64 << 20 });
  const line = r.stdout.split("\n").find((l) => l.startsWith('{"logs"'));
  assert.ok(line, `forge script produced no JSON result (exit ${r.status}): ${r.stderr.slice(-2000)}`);
  const returns = JSON.parse(line).returns;
  const ret = { 0: returns["0"], 1: returns["1"], 2: returns["2"], 3: returns["3"], refuseAll: returns.refuseAll ?? returns["4"], validator: returns.validator ?? returns["5"], validatorIdentity: returns.validatorIdentity ?? returns["6"] };
  const list = (v) => v.value.replace(/^\[|\]$/g, "").split(",").map((x) => x.trim().toLowerCase());
  const want = (k) => plan.profile.map((p) => p[k].toLowerCase());
  assert.deepEqual(list(ret["0"]), want("instance"), "script instances != JS");
  assert.deepEqual(list(ret["1"]), want("ruleInitcodeHash"), "script initcode hashes != JS");
  assert.deepEqual(list(ret["2"]), want("descriptor"), "script descriptors != JS twin");
  assert.deepEqual(list(ret["3"]), want("typeId"), "script Type ids != JS twin");
  assert.equal(ret.refuseAll.value.toLowerCase(), plan.addresses.refuseAllPolicy.toLowerCase(), "script RefuseAllPolicy");
  assert.equal(ret.validator.value.toLowerCase(), plan.addresses.filesFinalValidator.toLowerCase(), "script FilesFinalValidator");
  assert.equal(ret.validatorIdentity.value.toLowerCase(), plan.index.validatorIdentity.toLowerCase(), "script validator identity");
  scriptCheck = { ran: true, command: `forge script script/Genesis.s.sol --sig "profile(address)" ${plan.owner} --json`, equal: ["instances", "ruleInitcodeHashes", "descriptors", "typeIds", "refuseAll", "validator", "validatorIdentity"] };
}

// ---- named protocol constants, parsed from the Solidity sources (never a hand-typed twin) ---------------------------
const src = (rel) => readFileSync(join(root, rel), "utf8");
const block = (text, head, rel) => {
  const m = text.match(new RegExp(`\\n${head}[^{\\n]*\\{([\\s\\S]*?)\\n\\}`)); // a top-level block: its closing brace is in column 0
  assert.ok(m, `${rel}: \`${head}\` not found`);
  return m[1];
};
/** `NAME = <literal>` constants of a library: integers, `1 << n`, `type(uintN).max`, hex words and keccak256("…"). */
const libraryConstants = (rel, name) => {
  const out = {};
  for (const m of block(src(rel), `library ${name}`, rel).matchAll(/constant\s+(\w+)\s*=\s*([^;]+);/g)) {
    const e = m[2].trim();
    let k;
    if (/^[\d_]+$/.test(e)) out[m[1]] = Number(e.replaceAll("_", ""));
    else if ((k = e.match(/^1 << (\d+)$/))) out[m[1]] = 1 << Number(k[1]);
    else if ((k = e.match(/^type\(uint(\d+)\)\.max$/))) out[m[1]] = ((1n << BigInt(k[1])) - 1n).toString();
    else if (/^0x[0-9a-f]{64}$/.test(e)) out[m[1]] = e;
    else if ((k = e.match(/^keccak256\("([^"]+)"\)$/))) out[m[1]] = { preimage: k[1], id: keccak256(Buffer.from(k[1])) };
  }
  return out;
};
const enumCodes = (rel, name) => Object.fromEntries(block(src(rel).replace(/\/\/.*$/gm, ""), `enum ${name}`, rel).split(",").map((v, i) => [String(i), v.trim()]).filter(([, v]) => v));
const pick = (o, prefix) => Object.fromEntries(Object.entries(o).filter(([k]) => k.startsWith(prefix)).map(([k, v]) => [k.slice(prefix.length), v]));
const ACTIONS = "src/interfaces/Actions.sol", RESULTS = "src/interfaces/Results.sol", FILES_LIB = "src/lib/EfsFiles.sol", FILES_PROFILE = "src/profiles/FilesProfile.sol", TOPIC_PROFILE = "src/profiles/TopicProfile.sol";
const vocabulary = src(RESULTS).match(/STATUS_VOCABULARY_ID = keccak256\("([^"]+)"\)/)?.[1];
assert.ok(vocabulary, `${RESULTS}: STATUS_VOCABULARY_ID not found`);
const efsFiles = libraryConstants(FILES_LIB, "EfsFiles"), filesProfile = libraryConstants(FILES_PROFILE, "FilesProfile");
const topicProfile = libraryConstants(TOPIC_PROFILE, "TopicProfile");
const constants = {
  note: "parsed from the sources in `from` at release time; the ids are keccak256 of the UTF-8 preimage. Value 0 of each enum is reserved and never returned.",
  from: [ACTIONS, RESULTS, FILES_LIB, FILES_PROFILE, TOPIC_PROFILE],
  actionKinds: libraryConstants(ACTIONS, "ActionKind"),
  capabilities: libraryConstants(ACTIONS, "Capability"),
  purposes: libraryConstants(ACTIONS, "Purpose"),
  status: { id: keccak256(Buffer.from(vocabulary)), preimage: vocabulary, codes: enumCodes(RESULTS, "Status") },
  coverage: { codes: enumCodes(RESULTS, "Coverage") },
  files: {
    form: pick(efsFiles, "FORM_"), contentCarrier: pick(Object.fromEntries(Object.entries(efsFiles).filter(([k]) => k !== "CARRIER_LOCATION")), "CARRIER_"), externalCarrier: { LOCATION: efsFiles.CARRIER_LOCATION },
    hashAlg: pick(efsFiles, "HASH_"), alias: pick(efsFiles, "ALIAS_"), targetKind: pick(filesProfile, "TARGET_"), lengthMax: filesProfile.LENGTH_MAX, sha256Empty: filesProfile.SHA256_EMPTY,
    // fixed by each rule's law, not a named constant: FilesContentRule / FilesExternalContentRule refusal code 4
    contentVersion: 1, externalVersion: 2,
    chunking: { id: "efs/chunking/1", chunkPayload: efsFiles.CHUNK_PAYLOAD, spec: "docs/LARGE-FILES.md" },
    mediaType: { maxLength: filesProfile.MEDIA_MAX, empty: "unknown", spec: "docs/LARGE-FILES.md \"Media types\"", vectors: "test/vectors/media.json" },
  },
  topics: { wordMax: topicProfile.WORD_MAX, textMax: topicProfile.TEXT_MAX, refusedClasses: pick(topicProfile, "CLASS_"), spec: "docs/DESIGN.md §12.5", vectors: "test/vectors/topics.json" },
};
for (const [k, n] of [["actionKinds", 9], ["capabilities", 10], ["purposes", 6]]) assert.equal(Object.keys(constants[k]).length, n, `constants.${k}: expected ${n} entries`);
assert.equal(constants.status.codes["12"], "LIMIT_EXCEEDED");
assert.deepEqual(constants.files.form, { INLINE: 0, CONTENT: 1 });
assert.deepEqual(constants.files.contentCarrier, { INLINE: 0, REMOTE: 1, SPAN: 2 });
assert.equal(constants.files.chunking.chunkPayload, 8160);
assert.deepEqual(constants.topics.refusedClasses, { C1: 1, BIDI: 2, INVISIBLE: 3, JOINER: 4, NONCHARACTER: 5, WHITESPACE: 6 });
assert.equal(constants.topics.wordMax, 255);
assert.equal(constants.purposes.FOLDER.id, plan.index.units[0].purposeFilter ?? constants.purposes.FOLDER.id, "Purpose.FOLDER != the validator unit's purpose filter");

// ---- the planning gas model (gas/model.json, measured by tools/gas-model.mjs) and the joint envelope ----------------
// The Realm limits (64 actions, 16,384 body bytes) jointly allow a publication of about 28M gas, more than one
// transaction may carry under EIP-7825. The envelope says what one atomic publication realistically holds: the
// smallest of the gas budget and the two Realm limits, for a few named shapes, per fee schedule.
const MODEL = "gas/model.json";
const model = JSON.parse(src(MODEL));
assert.equal(model.schema, "efs-gas-model/1", `${MODEL}: run \`pnpm run gas:model\``);
// the cap and the headroom are the planning rule's (gas/model.json `planning`), so the envelope and the rule agree
assert.equal(model.planning?.txGasCap, 16_777_216, `${MODEL}: planning.txGasCap (EIP-7825); run \`pnpm run gas:model\``);
const TX_GAS_CAP = model.planning.txGasCap;
const HEADROOM_PERCENT = model.planning.headroomPercent; // intrinsic gas, calldata and the model's own error
// the floor inputs the model publishes are the ones this release's Realm activates (a stale model plans a wrong floor)
assert.deepEqual(model.profiles.prague.floor.workModel, plan.workModel, `${MODEL}: floor.workModel differs from the plan's work model; run \`pnpm run gas:model\``);
for (const k of ["floorFreshGas", "floorRewriteGas", "kernelTail"]) assert.equal(model.profiles.prague.floor.limits[k], plan.limits[k], `${MODEL}: prague floor.limits.${k} differs from the plan's limits`);
for (const k of ["maxActions", "maxBindsPerPublication", "maxBodyBytesPerPublication"]) assert.equal(model.planning.limits[k], plan.limits[k], `${MODEL}: planning.limits.${k} differs from the plan's limits`);
if (model.profiles.amsterdam) assert.deepEqual(model.profiles.amsterdam.floor.workModel, plan.workModel, `${MODEL}: amsterdam floor.workModel differs from the plan's work model`);
// a Glamsterdam Realm's floor prices (tools/deploy-plan.mjs GAS_SCHEDULES, the single table): a model planned with others is stale
if (model.profiles.amsterdam) for (const k of ["floorFreshGas", "floorRewriteGas", "kernelTail"]) assert.equal(model.profiles.amsterdam.floor.limits[k], GLAMSTERDAM_FLOOR[k], `${MODEL}: amsterdam floor.limits.${k} differs from GLAMSTERDAM_FLOOR (tools/deploy-plan.mjs GAS_SCHEDULES); run \`pnpm run gas:model\``);
// ---- test/vectors/floor-plan.json: the planning rule's largest publication per shape (tools/gas-plan.mjs) ----------
emit("test/vectors/floor-plan.json", toJSON(planVectors(model)));
const SHAPES = {
  editSmall: { what: "edit a file: PUBLISH files-child/1 form 0 with 100 bytes of content, rebind HEAD", actions: 2, bodyBytes: 196 },
  edit1k: { what: "the same with 1,024 bytes of content", actions: 2, bodyBytes: 1120 },
  createSmall: { what: "create a file: CREATE, PUBLISH files-root/1 form 0 with 100 bytes, PUBLISH a 12-byte name, BIND HEAD, BIND FOLDER", actions: 5, bodyBytes: 176 },
  create1k: { what: "the same with 1,024 bytes of content", actions: 5, bodyBytes: 1100 },
  chunk: { what: "PUBLISH one 8,192-byte files-bytes/1 chunk (8,160 file bytes)", actions: 1, bodyBytes: 8192 },
  spanNode: { what: "PUBLISH one files-span/1 node", actions: 1, bodyBytes: 96 },
};
const publishCost = (c, type, bytes) => c.publishNew[type] + c.perWord * Math.ceil(bytes / 32) + c.perByte * bytes;
const shapeCost = (c) => ({
  editSmall: publishCost(c, "files-child/1 form 0", 196) + c.bindHeadRebind,
  edit1k: publishCost(c, "files-child/1 form 0", 1120) + c.bindHeadRebind,
  createSmall: c.create + publishCost(c, "files-root/1 form 0", 164) + publishCost(c, "files-name/3", 12) + c.bindHeadFresh + c.bindFolderFreshFile,
  create1k: c.create + publishCost(c, "files-root/1 form 0", 1088) + publishCost(c, "files-name/3", 12) + c.bindHeadFresh + c.bindFolderFreshFile,
  chunk: publishCost(c, "files-bytes/1", 8192),
  spanNode: publishCost(c, "files-span/1", 96),
});
/** `capped`: the constants the cap applies to (all gas today; execution gas only under EIP-8037). */
const envelopeOf = (capped, total) => {
  const budget = Math.floor((TX_GAS_CAP * (100 - HEADROOM_PERCENT)) / 100) - capped.fixed;
  const [costCapped, costTotal] = [shapeCost(capped), shapeCost(total)];
  return Object.fromEntries(Object.entries(SHAPES).map(([k, s]) => {
    const by = { gas: Math.floor(budget / costCapped[k]), maxActions: Math.floor(plan.limits.maxActions / s.actions), maxBodyBytesPerPublication: Math.floor(plan.limits.maxBodyBytesPerPublication / s.bodyBytes) };
    const count = Math.max(0, Math.min(...Object.values(by)));
    return [k, { count, boundBy: Object.keys(by).find((b) => by[b] === count), gasEach: Math.round(costTotal[k]), gasOfPublication: Math.round(total.fixed + count * costTotal[k]) }];
  }));
};
const [mp, ma] = [model.profiles.prague, model.profiles.amsterdam];
const gasModel = {
  schema: model.schema, path: MODEL, sha256: sha256(readFileSync(join(root, MODEL))),
  note: "Planning only, keyed by fee schedule: never apply one schedule's constants on a chain running the other. gas(publication) = fixed + Σ actions; a new PUBLISH costs publishNew[type] + perWord × ceil(bodyBytes / 32) + perByte × bodyBytes. Excludes the 21,000 intrinsic cost and calldata, which the caller adds from the encoded transaction. eth_estimateGas on the exact call stays the authority before sending.",
  schedules: {
    prague: { status: "mainnet and Sepolia today (Fusaka); the cap counts all gas", hardforks: ["prague", "osaka"], constants: mp.constants, floor: mp.floor, maxAbsErrorPercent: mp.maxAbsErrorPercent },
    ...(ma ? { amsterdam: { status: "EIP-8037/8038 (Glamsterdam); the cap counts execution gas only, and the total must also fit the block", hardforks: ["amsterdam"], constants: ma.constants, executionGas: ma.split?.executionGas ?? null, floor: ma.floor, maxAbsErrorPercent: ma.maxAbsErrorPercent, maxAbsExecutionErrorPercent: ma.maxAbsExecutionErrorPercent } } : {}),
  },
  planning: model.planning,
  tagLists: model.tagLists,
  // the topic readers' call bounds (gas/model.json `reads`; the terms and rows stay in the model)
  reads: { callGasCap: model.reads.callGasCap, marginPercent: model.reads.marginPercent, recommended: Object.fromEntries(Object.entries(model.reads.schedules).map(([k, v]) => [k, v.recommended])) },
  envelope: {
    what: "how many of one shape fit one atomic publication: the smallest of the gas budget and the Realm limits maxActions and maxBodyBytesPerPublication. For user-facing messages; plan with the constants.",
    txGasCap: TX_GAS_CAP, txGasCapRule: "EIP-7825", headroomPercent: HEADROOM_PERCENT,
    budgetRule: "floor(txGasCap × (100 − headroomPercent) / 100) − fixed, on the gas the cap counts",
    limits: { maxActions: plan.limits.maxActions, maxBodyBytesPerPublication: plan.limits.maxBodyBytesPerPublication },
    shapes: SHAPES,
    prague: envelopeOf(mp.constants, mp.constants),
    ...(ma?.split?.executionGas ? { amsterdam: envelopeOf(ma.split.executionGas, ma.constants) } : {}),
  },
};
assert.equal(gasModel.envelope.prague.chunk.count, 2, "two 8 KB chunks per publication is the release's stated envelope today");

const storeId = (name) => idFromSnapshot(root, ABI_IDS.find((e) => e.name === name));

// ---- the manifest --------------------------------------------------------------------------------------------------
const settings = artifact("LedgerCore").settings;
const forgeVersion = (() => { try { return execFileSync("forge", ["--version"]).toString().split("\n")[0].trim(); } catch { return null; } })();
const dirty = git("status", "--porcelain");
const manifest = {
  schema: "efs-contracts-release/1",
  version: "0.0.0-s1b.3-local",
  status: "local fixture release (not reviewed, not published)",
  source: { commit: git("rev-parse", "HEAD"), tree: git("rev-parse", "HEAD^{tree}"), dirty: dirty ? dirty.split("\n").length : 0, standardJsonInputHash: null },
  toolchain: {
    solc: artifact("LedgerCore").compiler.version, evmVersion: settings.evmVersion, optimizer: settings.optimizer, viaIR: settings.viaIR, bytecodeHash: settings.metadata?.bytecodeHash, cborMetadata: true,
    foundry: forgeVersion, node: process.version, viem: JSON.parse(readFileSync(join(root, "node_modules/viem/package.json"), "utf8")).version,
  },
  buildPlatform: { os: platform(), osRelease: osRelease(), arch: arch() },
  reproducibility: { builds: [OUT, AST_OUT].map((p) => relative(root, p)), unitsCompared: reproducible, runtimeAndInitcodeIdentical: reproducible === Object.keys(UNITS).length, note: "the AST build is a second full compile with the identity settings plus AST output; tools/deploy-plan.mjs refuses any unit whose bytes differ" },
  files,
  contracts,
  profiles: {
    declarationKey: plan.declarationKey,
    types: plan.profile.map(({ declarationSig, ...p }) => ({ ...p, declarationSig, grade: "NATIVE", wrapperVersion: 0 })),
    acceptors: { RefuseAllPolicy: { address: plan.addresses.refuseAllPolicy, codehash: contracts.RefuseAllPolicy.deployedBytecodeHash } },
    wrappers: [],
    index: { generation: 1, address: plan.index.address, runtimeCodehash: plan.index.runtimeCodehash, reads: plan.index.reads, manifestHash: plan.index.manifestHash, families: plan.index.families, units: plan.index.units, digestSpecs: plan.index.specs, workModel: plan.workModel, stores: { posting: plan.addresses.postingStore, bitmap: plan.addresses.bitmapStore } },
    limits: plan.limits,
    layoutId: plan.layoutId,
    hotAbiId: plan.hotAbiId,
    hotAbiIdName: plan.hotAbiIdString,
    readers: { lens: plan.readers.lens, filesPage: plan.readers.filesPage, topicMine: plan.readers.topicMine, topicEveryone: plan.readers.topicEveryone, topicLookup: plan.readers.topicLookup, web3Gateway: plan.gateway, directory: plan.addresses.readerDirectory, facets: { ledgerReads: plan.addresses.ledgerReads, ledgerViews: plan.addresses.ledgerViews } },
    statusVocabularyId: constants.status.id,
    storeAbiIds: { posting: storeId("efs/posting-store/2"), bitmap: storeId("efs/bitmap-store/2") },
    abiIdRule: "keccak(name ‖ for each function sorted by selector: selector ‖ keccak(canonical output tuple)) (tools/abi-id.mjs)",
    indexProfiles: { physical: keccak256(Buffer.from("efs/index-layout/1:stores:inline-singleton:five-u48:live-bits-in-head")), callback: keccak256(Buffer.from("efs/index-callback/4:ordered-prefix:static-final:effect-24:refs")) },
    crossCheck: scriptCheck,
  },
  constants,
  gasModel,
  consumer: { pragmaFloor: "^0.8.27", tested: [{ solc: "0.8.27", viaIR: false, profile: "closure" }, { solc: artifact("LedgerCore").compiler.version, viaIR: true, evm: settings.evmVersion, profile: "default" }], remapping: "@efs/contracts/=src/" },
  privilegedRoles: { controllerOwner: plan.owner, proxyAdminsOwner: "the Realm's RealmController", steward: null, note: "the fixture key owns the controller; administrator power is total before freeze (SECURITY.md)" },
  errors: { path: "release/errors.json", sha256: sha256(Buffer.from(generated.get("release/errors.json"))), count: Object.keys(errors).length },
  abi: { interfaces: "test/snapshots/abi/", units: "artifacts/" },
  vectors: Object.fromEntries(["vectors/layout.json", "test/vectors/ids.json", "test/vectors/media.json", "test/vectors/numbers.json", "test/vectors/topics.json", "test/vectors/names.json", "test/vectors/floor-plan.json"].map((p) => [p, sha256(generated.has(p) ? Buffer.from(generated.get(p)) : readFileSync(join(root, p)))])),
  dependencyRoot: null,
  deployPlan: { path: "deploy/plan.json", genesis: plan.addresses.genesis, factory: plan.factory },
};
// what a second machine cannot reproduce, and so --check does not compare
const stable = ({ source, buildPlatform, reproducibility, ...m }) => {
  const { foundry, node, ...toolchain } = m.toolchain ?? {};
  const { crossCheck, ...profiles } = m.profiles ?? {};
  return { ...m, toolchain, profiles };
};
emit("release/release.json", toJSON(jsonable(manifest)), stable);
if (CHECK) {
  // deploy/plan.json is tools/deploy-plan.mjs's output for the default chain and salt
  emit("deploy/plan.json", toJSON(planDocument(plan)));
  const committed = new Set(readdirSync(join(root, "artifacts")).filter((f) => f.endsWith(".json")).map((f) => `artifacts/${f}`));
  for (const f of committed) if (!generated.has(f)) drift.push(`${f}: committed but no longer generated`);
  // the committed sample deployment names this manifest and this plan
  const sample = join(root, "release/efs-deployment.json");
  if (existsSync(sample)) {
    const dep = JSON.parse(readFileSync(sample, "utf8"));
    if (dep.releaseDigest !== sha256(readFileSync(join(root, "release/release.json")))) drift.push("release/efs-deployment.json: releaseDigest is not sha256(release/release.json) (run `efs-fixture up --name sample --write-release`)");
    if (dep.planHash !== planDocument(plan).planHash) drift.push("release/efs-deployment.json: planHash is not this build's plan");
  }
  if (drift.length) {
    console.error(`release: the committed snapshot does not match this build (${drift.length}):\n  ${drift.join("\n  ")}\nRegenerate it in the same push: forge build, the AST build, \`pnpm run release\`, \`pnpm run plan\` (tools/RELEASE.md).`);
    process.exit(1);
  }
  console.log(`release: the committed snapshot matches this build (${generated.size} documents: release/, artifacts/, deploy/plan.json, test/vectors/media.json, test/vectors/numbers.json, test/vectors/topics.json, test/vectors/names.json${scriptCheck.ran ? "; FilesTypes/TopicTypes twin == forge script" : ""})`);
  process.exit(0);
}
const digest = sha256(readFileSync(join(root, "release/release.json")));
console.log(`release: release/release.json (${Object.keys(contracts).length} units, ${Object.keys(files).length} source files, ${Object.keys(errors).length} errors, ${reproducible}/${Object.keys(UNITS).length} double-built identical${scriptCheck.ran ? ", FilesTypes twin == forge script" : ""}) digest ${digest}`);
