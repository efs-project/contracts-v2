// SPDX-License-Identifier: MIT
// The release manifest of design §13 (`efs-contracts-release/1`), generated from the identity build in out/, the
// auxiliary AST build in out/release-ast (immutable names; its bytecode must equal out/'s, the double-build check)
// and the chain-free plan facts of tools/deploy-plan.mjs. It also writes release/errors.json (the error catalog)
// and artifacts/<Unit>.json (ABI union, bytecode, immutables, method identifiers) and cross-checks the JS Files
// twin against the Solidity FilesTypes through `forge script script/Genesis.s.sol --sig "profile(address)"`.
//
//   node tools/release.mjs [--skip-script 1]
//
// Digest = sha256(release/release.json); the fixture copies it into efs-deployment/1.
import assert from "node:assert/strict";
import { execFileSync, spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { existsSync, mkdirSync, readFileSync, readdirSync, writeFileSync } from "node:fs";
import { arch, platform, release as osRelease } from "node:os";
import { join } from "node:path";
import { keccak256, toFunctionSelector } from "viem";
import { AST_OUT, OUT, UNITS, artifact, buildPlan, immutableLayout, jsonable, parseArgs, root, toJSON } from "./deploy-plan.mjs";

const o = parseArgs(process.argv.slice(2), ["skip-script"]);
const sha256 = (buf) => `0x${createHash("sha256").update(buf).digest("hex")}`;
const git = (...args) => { try { return execFileSync("git", args, { cwd: root }).toString().trim(); } catch { return null; } };

const plan = await buildPlan();
const sizes = JSON.parse(readFileSync(join(root, "test/snapshots/sizes.json"), "utf8"));
const budgetOf = (name) => sizes.units.find((u) => u.name === name) ?? null;

// ---- per-unit facts ------------------------------------------------------------------------------------------------
const stepOf = (name) => plan.steps.find((s) => s.kind === "CREATE2" && s.contract === name);
const createdOf = (label) => plan.steps.find((s) => s.id === "G18").creates.find((c) => c.label === label);
const realmSpecific = new Set(["RealmGenesis", "PostingStore", "BitmapStore", "RealmIndex", "RealmController", "TransparentUpgradeableProxy", "ProxyAdmin"]);
const contracts = {};
let reproducible = 0;
for (const name of Object.keys(UNITS)) {
  const a = artifact(name);
  const imm = immutableLayout(name);
  if (existsSync(join(root, AST_OUT, `${UNITS[name]}.sol`, `${name}.json`))) reproducible++;
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
  const meta = JSON.parse(readFileSync(join(root, OUT, `${UNITS[name]}.sol`, `${name}.json`), "utf8")).metadata;
  for (const src of Object.keys(meta.sources)) files[src] ??= sha256(readFileSync(join(root, src)));
}

// ---- the error catalog (design §5.6): file-level errors with the retry class in the trailing comment ----------------
const errors = {};
const walk = (dir) => readdirSync(join(root, dir), { withFileTypes: true }).flatMap((e) => (e.isDirectory() ? walk(`${dir}/${e.name}`) : e.name.endsWith(".sol") ? [`${dir}/${e.name}`] : []));
for (const path of walk("src").sort()) {
  for (const line of readFileSync(join(root, path), "utf8").split("\n")) {
    const m = line.match(/^error\s+(\w+)\(([^)]*)\);\s*(?:\/\/\s*(.*))?$/);
    if (!m) continue;
    const params = m[2].trim() ? m[2].split(",").map((p) => p.trim().split(/\s+/)) : [];
    const sig = `${m[1]}(${params.map(([t]) => t.replace(/^uint$/, "uint256")).join(",")})`;
    const comment = (m[3] ?? "").trim();
    const cls = comment.match(/^(none|reprepare|resubmit|wait)\b/)?.[1] ?? null;
    errors[toFunctionSelector(sig)] = { name: m[1], signature: sig, args: params.map(([t, n]) => ({ type: t, name: n ?? "" })), source: path, retryClass: cls, meaning: comment.replace(/^(none|reprepare|resubmit|wait)\b[:\s]*/, "") || null };
  }
}
const snap = JSON.parse(readFileSync(join(root, "test/snapshots/abi/Errors.json"), "utf8")).errors;
for (const [sel, sig] of Object.entries(snap)) assert.equal(errors[sel]?.signature, sig, `error catalog: ${sig} (${sel}) from test/snapshots/abi/Errors.json not reproduced`);
mkdirSync(join(root, "release"), { recursive: true });
writeFileSync(join(root, "release/errors.json"), toJSON({ schema: "efs-errors/1", source: "src/**/*.sol file-level errors; retry class = the trailing comment's first word", errors: Object.fromEntries(Object.entries(errors).sort(([, x], [, y]) => (x.name < y.name ? -1 : 1))) }));

// ---- artifacts/: the deployable units' ABI (kernel = core ∪ apply ∪ ingress ∪ control fragments), bytecode, ids -----
mkdirSync(join(root, "artifacts"), { recursive: true });
const union = (names) => {
  const seen = new Map();
  for (const n of names) for (const item of artifact(n).abi) {
    const k = `${item.type} ${item.name ?? ""}(${(item.inputs ?? []).map((i) => i.type).join(",")})`;
    if (item.type === "constructor" && n !== names[0]) continue;
    if (!seen.has(k) && (n === names[0] || item.type === "event" || item.type === "error")) seen.set(k, item);
  }
  return [...seen.values()];
};
for (const name of Object.keys(UNITS)) {
  const a = artifact(name);
  const raw = JSON.parse(readFileSync(join(root, OUT, `${UNITS[name]}.sol`, `${name}.json`), "utf8"));
  const abi = name === "LedgerCore" ? union(["LedgerCore", "LedgerApply", "LedgerIngress", "LedgerControl"]) : a.abi;
  writeFileSync(join(root, "artifacts", `${name}.json`), toJSON({ schema: "efs-artifact/1", name, source: a.source, abi, methodIdentifiers: raw.methodIdentifiers, bytecode: a.bytecode, deployedBytecode: a.runtime, immutables: contracts[name].immutables, storageLayout: "test/snapshots/layout/", interfaces: "test/snapshots/abi/" }));
}

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
  reproducibility: { builds: [OUT, AST_OUT], unitsCompared: reproducible, runtimeAndInitcodeIdentical: reproducible === Object.keys(UNITS).length, note: "the AST build is a second full compile with the identity settings plus AST output; tools/deploy-plan.mjs refuses any unit whose bytes differ" },
  files,
  contracts,
  profiles: {
    declarationKey: plan.declarationKey,
    types: plan.profile.map(({ declarationSig, ...p }) => ({ ...p, declarationSig, grade: "NATIVE", wrapperVersion: 0 })),
    acceptors: { RefuseAllPolicy: { address: plan.addresses.refuseAllPolicy, codehash: contracts.RefuseAllPolicy.deployedBytecodeHash } },
    wrappers: [],
    index: { generation: 1, manifestHash: plan.index.manifestHash, families: plan.index.families, units: plan.index.units, digestSpecs: plan.index.specs, workModel: plan.workModel, stores: { posting: plan.addresses.postingStore, bitmap: plan.addresses.bitmapStore } },
    limits: plan.limits,
    layoutId: plan.layoutId,
    hotAbiId: plan.hotAbiId,
    statusVocabularyId: keccak256(Buffer.from("efs2/status-vocabulary/1")),
    storeAbiIds: { posting: keccak256(Buffer.from("efs2/posting-store/1")), bitmap: keccak256(Buffer.from("efs2/bitmap-store/1")) },
    indexProfiles: { physical: keccak256(Buffer.from("efs2/index-layout/1:stores:inline-singleton:five-u48:live-bits-in-head")), callback: keccak256(Buffer.from("efs2/index-callback/3:ordered-prefix:static-final:effect-24:refs")) },
    crossCheck: scriptCheck,
  },
  consumer: { pragmaFloor: "^0.8.27", tested: [{ solc: "0.8.27", viaIR: false, profile: "closure" }, { solc: artifact("LedgerCore").compiler.version, viaIR: true, evm: settings.evmVersion, profile: "default" }], remapping: "@efs/contracts-v2/=src/" },
  privilegedRoles: { controllerOwner: plan.owner, proxyAdminsOwner: "the Realm's RealmController", steward: null, note: "the fixture key owns the controller; administrator power is total before freeze (SECURITY.md)" },
  errors: { path: "release/errors.json", sha256: sha256(readFileSync(join(root, "release/errors.json"))), count: Object.keys(errors).length },
  abi: { interfaces: "test/snapshots/abi/", units: "artifacts/" },
  vectors: Object.fromEntries(["vectors/layout.json", "test/vectors/ids.json"].map((p) => [p, sha256(readFileSync(join(root, p)))])),
  dependencyRoot: null,
  deployPlan: { path: "deploy/plan.json", genesis: plan.addresses.genesis, factory: plan.factory },
};
writeFileSync(join(root, "release/release.json"), toJSON(jsonable(manifest)));
const digest = sha256(readFileSync(join(root, "release/release.json")));
console.log(`release: release/release.json (${Object.keys(contracts).length} units, ${Object.keys(files).length} source files, ${Object.keys(errors).length} errors, ${reproducible}/${Object.keys(UNITS).length} double-built identical${scriptCheck.ran ? ", FilesTypes twin == forge script" : ""}) digest ${digest}`);
