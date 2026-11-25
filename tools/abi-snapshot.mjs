// SPDX-License-Identifier: MIT
// ABI snapshot of the interfaces under src/interfaces/ (Node built-ins only). Run after `forge build`:
//
//   node tools/abi-snapshot.mjs           write test/snapshots/abi/<Interface>.json   (pnpm abi:snapshot)
//   node tools/abi-snapshot.mjs --check   exit 1 with a readable diff when the build    (pnpm abi:check)
//                                         differs from the committed snapshot, or when a pinned ABI id
//                                         (tools/abi-id.mjs) differs from its recomputation from the snapshot
//
// Each snapshot holds the interface's ABI items sorted by type and name, its method identifiers
// (selector → signature), its error and event signatures with their keccak selectors and topics, and every
// struct reachable from the ABI with its fields as the ABI states them. Interfaces are found in the sources
// (`interface Name` at file level) and read from their Foundry artifacts; an artifact whose recorded source hash
// differs from the file on disk is stale and refused. File-level errors and events (src/interfaces/Errors.sol)
// have no artifact, so they are read from the source, restricted to elementary parameter types, and written to
// test/snapshots/abi/<File>.json. Every function selector computed here is cross-checked against solc's
// methodIdentifiers, which also proves the keccak below.
import assert from "node:assert/strict";
import { existsSync, mkdirSync, readFileSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { basename, dirname, join, relative, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const SRC = "src/interfaces";
const INTERNAL = "src/interfaces/internal/";
const OUT = "out";
const SNAP = "test/snapshots/abi";

const args = process.argv.slice(2);
if (args.some((a) => a !== "--check")) {
  console.error("usage: node tools/abi-snapshot.mjs [--check]");
  process.exit(2);
}
const check = args.includes("--check");

import { keccak256 } from "./keccak.mjs";
import { ABI_IDS, checkPins, idFromSnapshot } from "./abi-id.mjs";

// ---- sources ----
const files = (dir) =>
  existsSync(join(root, dir))
    ? readdirSync(join(root, dir), { withFileTypes: true })
        .sort((a, b) => a.name.localeCompare(b.name))
        .flatMap((e) => (e.isDirectory() ? files(`${dir}/${e.name}`) : [`${dir}/${e.name}`]))
    : [];

// Blanks comments (keeping string literals and line structure) so declarations can be matched safely.
function stripComments(src) {
  let out = "";
  for (let i = 0; i < src.length; ) {
    const two = src.slice(i, i + 2);
    if (two === "//") {
      while (i < src.length && src[i] !== "\n") i++;
    } else if (two === "/*") {
      const end = src.indexOf("*/", i + 2);
      const stop = end < 0 ? src.length : end + 2;
      out += src.slice(i, stop).replace(/[^\n]/g, " ");
      i = stop;
    } else if (src[i] === '"' || src[i] === "'") {
      const q = src[i];
      let j = i + 1;
      while (j < src.length && src[j] !== q) j += src[j] === "\\" ? 2 : 1;
      out += src.slice(i, j + 1);
      i = j + 1;
    } else {
      out += src[i++];
    }
  }
  return out;
}

// The text outside every `{ ... }` body (contracts, interfaces, libraries, structs, enums, functions).
function fileLevel(code) {
  let depth = 0;
  let out = "";
  for (const ch of code) {
    if (ch === "{") depth++;
    if (depth === 0) out += ch;
    if (ch === "}") depth--;
  }
  return out;
}

const ELEMENTARY = /^(?:address|bool|string|bytes(?:[1-9]|[12]\d|3[0-2])?|u?int(?:8|16|24|32|40|48|56|64|72|80|88|96|104|112|120|128|136|144|152|160|168|176|184|192|200|208|216|224|232|240|248|256)?)(?:\[\d*\])*$/;
function parseParams(list, path, decl, kind) {
  const text = list.trim();
  if (text === "") return [];
  return text.split(",").map((raw) => {
    const words = raw.trim().split(/\s+/);
    const type = words[0];
    const indexed = kind === "event" && words.includes("indexed");
    const name = words.filter((w) => w !== "indexed" && w !== type)[0] ?? "";
    assert.ok(
      ELEMENTARY.test(type),
      `${path}: file-level ${kind} ${decl} has parameter type '${type}'; abi-snapshot reads file-level declarations ` +
        "from source and supports elementary types only (declare it inside an interface or extend the tool)",
    );
    const canonical = type.replace(/^uint(?=\[|$)/, "uint256").replace(/^int(?=\[|$)/, "int256");
    const param = { internalType: canonical, name, type: canonical };
    return kind === "event" ? { indexed, ...param } : param;
  });
}

// ---- ABI helpers ----
const canonicalType = (p) =>
  p.type.startsWith("tuple") ? `(${p.components.map(canonicalType).join(",")})${p.type.slice(5)}` : p.type;
const signature = (item) => `${item.name}(${(item.inputs ?? []).map(canonicalType).join(",")})`;
const sortKey = (item) => `${item.type}\u0000${item.name ?? ""}\u0000${item.name ? signature(item) : ""}`;
const bySignature = (a, b) => (a[1] < b[1] ? -1 : a[1] > b[1] ? 1 : 0);

function collectStructs(params, structs, where) {
  for (const p of params ?? []) {
    if (!p.components) continue;
    const name = p.internalType.replace(/^struct /, "").replace(/(\[\d*\])+$/, "");
    const fields = p.components.map((c) => ({ internalType: c.internalType, name: c.name, type: c.type }));
    if (name in structs) {
      assert.deepEqual(fields, structs[name], `${where}: struct ${name} appears with two field lists`);
    } else {
      structs[name] = fields;
    }
    collectStructs(p.components, structs, where);
  }
}

function snapshotOf({ name, source, closure, abi, solcMethods }) {
  const items = [...abi].sort((a, b) => (sortKey(a) < sortKey(b) ? -1 : sortKey(a) > sortKey(b) ? 1 : 0));
  const functions = items.filter((i) => i.type === "function").map((i) => [keccak256(signature(i)).slice(0, 10), signature(i)]);
  if (solcMethods) {
    const ours = Object.fromEntries(functions.map(([sel, sig]) => [sig, sel.slice(2)]));
    assert.deepEqual(ours, solcMethods, `${source}:${name}: computed selectors differ from solc's methodIdentifiers`);
  }
  const events = items.filter((i) => i.type === "event").map((i) => [keccak256(signature(i)), signature(i)]);
  const errors = items.filter((i) => i.type === "error").map((i) => [keccak256(signature(i)).slice(0, 10), signature(i)]);
  const structs = {};
  for (const item of items) {
    collectStructs(item.inputs, structs, `${source}:${name}`);
    collectStructs(item.outputs, structs, `${source}:${name}`);
  }
  return {
    name,
    source,
    closure,
    methodIdentifiers: Object.fromEntries(functions.sort(bySignature)),
    events: Object.fromEntries(events.sort(bySignature)),
    errors: Object.fromEntries(errors.sort(bySignature)),
    structs: Object.fromEntries(Object.entries(structs).sort(([a], [b]) => (a < b ? -1 : 1))),
    abi: items,
  };
}

// ---- artifacts ----
// Foundry writes out/<File>.sol/<Name>.json, or <Name>.<solc>.json when several compilers built the file; the
// artifact is matched by the compilation target recorded in its metadata, never by its directory alone.
const artifactIndex = new Map();
function indexArtifacts(dir) {
  for (const e of readdirSync(join(root, dir), { withFileTypes: true })) {
    if (e.isDirectory()) {
      if (e.name !== "build-info") indexArtifacts(`${dir}/${e.name}`);
    } else if (e.name.endsWith(".json")) {
      const name = e.name.split(".")[0];
      if (!artifactIndex.has(name)) artifactIndex.set(name, []);
      artifactIndex.get(name).push(`${dir}/${e.name}`);
    }
  }
}
assert.ok(existsSync(join(root, OUT)), `${OUT}/ is missing: run \`forge build\` first`);
indexArtifacts(OUT);

function artifactFor(source, name, text) {
  const matches = (artifactIndex.get(name) ?? [])
    .map((path) => ({ path, artifact: JSON.parse(readFileSync(join(root, path), "utf8")) }))
    .filter(({ artifact }) => artifact.metadata?.settings?.compilationTarget?.[source] === name);
  assert.ok(matches.length > 0, `${source}:${name}: no artifact under ${OUT}/; run \`forge build\` first`);
  // Only artifacts built from the file as it is on disk count (another profile's output may be older).
  const hash = keccak256(text);
  const fresh = matches.filter(({ artifact }) => artifact.metadata.sources?.[source]?.keccak256 === hash);
  assert.ok(
    fresh.length > 0,
    `${matches.map((m) => m.path).join(", ")} built from a different ${source}; run \`forge build\` first`,
  );
  for (const { path, artifact } of fresh) {
    assert.deepEqual(artifact.abi, fresh[0].artifact.abi, `${path} and ${fresh[0].path} disagree on the ABI`);
  }
  return fresh[0].artifact;
}

// ---- build the expected snapshot set ----
const expected = new Map();
const put = (fileName, snapshot) => {
  assert.ok(!expected.has(fileName), `two snapshots named ${fileName}`);
  expected.set(fileName, `${JSON.stringify(snapshot, null, 2)}\n`);
};
for (const source of files(SRC).filter((p) => p.endsWith(".sol"))) {
  const text = readFileSync(join(root, source), "utf8");
  const top = fileLevel(stripComments(text));
  const closure = !source.startsWith(INTERNAL);
  for (const m of top.matchAll(/\binterface\s+([A-Za-z_$][\w$]*)/g)) {
    const artifact = artifactFor(source, m[1], text);
    put(`${m[1]}.json`, snapshotOf({ name: m[1], source, closure, abi: artifact.abi, solcMethods: artifact.methodIdentifiers }));
  }
  const declarations = [...top.matchAll(/\b(error|event)\s+([A-Za-z_$][\w$]*)\s*\(([^)]*)\)\s*(anonymous\s*)?;/g)];
  assert.equal(
    declarations.length,
    [...top.matchAll(/\b(?:error|event)\s+[A-Za-z_$]/g)].length,
    `${source}: a file-level error or event declaration could not be parsed`,
  );
  if (declarations.length > 0) {
    const abi = declarations.map(([, kind, decl, params, anonymous]) => {
      assert.ok(!anonymous, `${source}: anonymous file-level event ${decl} is not supported`);
      const inputs = parseParams(params, source, decl, kind);
      return kind === "event" ? { anonymous: false, inputs, name: decl, type: "event" } : { inputs, name: decl, type: "error" };
    });
    put(`${basename(source, ".sol")}.json`, snapshotOf({ name: `${basename(source)} (file level)`, source, closure, abi }));
  }
}

// ---- write or check ----
const snapDir = join(root, SNAP);
const present = existsSync(snapDir) ? readdirSync(snapDir).filter((f) => f.endsWith(".json")).sort() : [];

if (!check) {
  mkdirSync(snapDir, { recursive: true });
  for (const f of present.filter((f) => !expected.has(f))) rmSync(join(snapDir, f));
  for (const [f, body] of [...expected].sort()) writeFileSync(join(snapDir, f), body);
  const count = (key) => [...expected.values()].reduce((n, b) => n + Object.keys(JSON.parse(b)[key]).length, 0);
  console.log(
    `abi-snapshot: wrote ${expected.size} snapshots to ${relative(root, snapDir)}/ ` +
      `(${count("methodIdentifiers")} selectors, ${count("events")} events, ${count("errors")} errors, ${count("structs")} struct entries)`,
  );
  process.exit(0);
}

const lines = [];
const fieldList = (fields) => fields.map((f) => `${f.internalType} ${f.name}`).join(", ");
function diffMap(file, section, before, after, render = (k, v) => `${k}  ${v}`) {
  for (const k of Object.keys(before)) {
    if (!(k in after)) lines.push(`${file} ${section}: - ${render(k, before[k])}`);
    else if (JSON.stringify(before[k]) !== JSON.stringify(after[k])) {
      lines.push(`${file} ${section}: - ${render(k, before[k])}`, `${file} ${section}: + ${render(k, after[k])}`);
    }
  }
  for (const k of Object.keys(after)) if (!(k in before)) lines.push(`${file} ${section}: + ${render(k, after[k])}`);
}
for (const f of present.filter((f) => !expected.has(f))) lines.push(`${f}: committed snapshot has no interface in the build (removed or renamed)`);
for (const [f, body] of [...expected].sort()) {
  if (!present.includes(f)) {
    lines.push(`${f}: new interface without a committed snapshot`);
    continue;
  }
  const committed = readFileSync(join(snapDir, f), "utf8");
  if (committed === body) continue;
  const before = JSON.parse(committed);
  const after = JSON.parse(body);
  const start = lines.length;
  for (const key of ["name", "source", "closure"]) {
    if (before[key] !== after[key]) lines.push(`${f} ${key}: ${JSON.stringify(before[key])} -> ${JSON.stringify(after[key])}`);
  }
  diffMap(f, "selector", before.methodIdentifiers ?? {}, after.methodIdentifiers);
  diffMap(f, "event", before.events ?? {}, after.events);
  diffMap(f, "error", before.errors ?? {}, after.errors);
  diffMap(f, "struct", before.structs ?? {}, after.structs, (k, v) => `${k} { ${fieldList(v)} }`);
  const keyed = (abi) => Object.fromEntries((abi ?? []).map((i) => [`${i.type} ${i.name ? signature(i) : ""}`.trim(), i]));
  const describeItem = (i) =>
    `${i.stateMutability ?? ""} (${(i.inputs ?? []).map((p) => `${p.internalType}${p.indexed ? " indexed" : ""} ${p.name}`.trim()).join(", ")})` +
    (i.outputs ? ` returns (${i.outputs.map((p) => `${p.internalType} ${p.name}`.trim()).join(", ")})` : "");
  diffMap(f, "abi", keyed(before.abi), keyed(after.abi), (k, v) => `${k}  ${describeItem(v).trim()}`);
  if (lines.length === start) lines.push(`${f}: same content, different formatting`);
}
if (lines.length > 0) {
  console.error(`abi-snapshot: the build differs from ${SNAP}/ (${lines.length} line(s); - committed, + build):`);
  for (const l of lines) console.error(`  ${l}`);
  console.error("Review the change; if it is intended, run `pnpm abi:snapshot` and commit the updated snapshot.");
  process.exit(1);
}
console.log(`abi-snapshot: ${expected.size} snapshots in ${SNAP}/ match the build`);

// The ABI ids that commit to their functions (tools/abi-id.mjs): recomputed from the committed snapshots, every pin
// must equal its id.
const pinLines = checkPins(root);
if (pinLines.length > 0) {
  console.error(`abi-snapshot: ${pinLines.length} pinned ABI id(s) differ from the committed snapshots (tools/abi-id.mjs):`);
  for (const l of pinLines) console.error(`  ${l}`);
  process.exit(1);
}
console.log(`abi-snapshot: ${ABI_IDS.length} ABI ids recomputed; every pin matches (${ABI_IDS.map((e) => `${e.name} ${idFromSnapshot(root, e).slice(0, 10)}…`).join(", ")})`);
