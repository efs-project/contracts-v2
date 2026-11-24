// SPDX-License-Identifier: MIT
// ABI snapshot of the interfaces under src/interfaces/ (Node built-ins only). Run after `forge build`:
//
//   node tools/abi-snapshot.mjs           write test/snapshots/abi/<Interface>.json   (pnpm abi:snapshot)
//   node tools/abi-snapshot.mjs --check   exit 1 with a readable diff when the build    (pnpm abi:check)
//                                         differs from the committed snapshot
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

// ---- keccak-256 (the pre-NIST padding Ethereum uses; node:crypto's sha3-256 is a different function) ----
const MASK = (1n << 64n) - 1n;
const RC = [
  0x0000000000000001n, 0x0000000000008082n, 0x800000000000808an, 0x8000000080008000n,
  0x000000000000808bn, 0x0000000080000001n, 0x8000000080008081n, 0x8000000000008009n,
  0x000000000000008an, 0x0000000000000088n, 0x0000000080008009n, 0x000000008000000an,
  0x000000008000808bn, 0x800000000000008bn, 0x8000000000008089n, 0x8000000000008003n,
  0x8000000000008002n, 0x8000000000000080n, 0x000000000000800an, 0x800000008000000an,
  0x8000000080008081n, 0x8000000000008080n, 0x0000000080000001n, 0x8000000080008008n,
];
// ROT[x][y]: rotation offset of lane (x, y); the state is indexed x + 5y.
const ROT = [
  [0, 36, 3, 41, 18],
  [1, 44, 10, 45, 2],
  [62, 6, 43, 15, 61],
  [28, 55, 25, 21, 56],
  [27, 20, 39, 8, 14],
];
const rotl = (v, n) => (n === 0 ? v : ((v << BigInt(n)) | (v >> BigInt(64 - n))) & MASK);
function keccakF(s) {
  for (let round = 0; round < 24; round++) {
    const c = [0, 1, 2, 3, 4].map((x) => s[x] ^ s[x + 5] ^ s[x + 10] ^ s[x + 15] ^ s[x + 20]);
    for (let x = 0; x < 5; x++) {
      const d = c[(x + 4) % 5] ^ rotl(c[(x + 1) % 5], 1);
      for (let y = 0; y < 5; y++) s[x + 5 * y] ^= d;
    }
    const b = new Array(25);
    for (let x = 0; x < 5; x++) {
      for (let y = 0; y < 5; y++) b[y + 5 * ((2 * x + 3 * y) % 5)] = rotl(s[x + 5 * y], ROT[x][y]);
    }
    for (let x = 0; x < 5; x++) {
      for (let y = 0; y < 5; y++) {
        s[x + 5 * y] = b[x + 5 * y] ^ (~b[((x + 1) % 5) + 5 * y] & MASK & b[((x + 2) % 5) + 5 * y]);
      }
    }
    s[0] ^= RC[round];
  }
}
function keccak256(input) {
  const data = typeof input === "string" ? Buffer.from(input, "utf8") : Buffer.from(input);
  const rate = 136;
  const padded = Buffer.alloc(data.length + rate - (data.length % rate));
  data.copy(padded);
  padded[data.length] ^= 0x01;
  padded[padded.length - 1] ^= 0x80;
  const s = new Array(25).fill(0n);
  for (let off = 0; off < padded.length; off += rate) {
    for (let i = 0; i < rate / 8; i++) s[i] ^= padded.readBigUInt64LE(off + 8 * i);
    keccakF(s);
  }
  const out = Buffer.alloc(32);
  for (let i = 0; i < 4; i++) out.writeBigUInt64LE(s[i], 8 * i);
  return `0x${out.toString("hex")}`;
}
assert.equal(keccak256(""), "0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470", "keccak self-test");
assert.equal(keccak256("transfer(address,uint256)").slice(0, 10), "0xa9059cbb", "keccak self-test");

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
