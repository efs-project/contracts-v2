// SPDX-License-Identifier: MIT
// Storage-layout generator (design §4.1): reads the compiler's storage layout of the test-only
// probes (test/harness/LayoutProbe.sol), combines it with the ERC-7201 namespace roots and writes
//   - src/core/layout/Layout.sol   roots, member slots, mapping/array derivations, per-word unpackers
//   - vectors/layout.json          the same manifest for the SDK's slot codecs and the oracle
//   - test/snapshots/layout/*.json the raw `forge inspect` output per probe (diffed in CI)
// `node tools/layout.mjs --check` regenerates in memory and exits 1 when any committed file differs.
// Needs `forge` (it runs `forge inspect`) and viem for keccak256 (the one tools dependency).
import { spawnSync } from "node:child_process";
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { encodeAbiParameters, keccak256, stringToHex, toHex } from "viem";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const check = process.argv.includes("--check");

// Namespace ids by probe field label; the order is the order of the design's §4.1 table.
const PROBES = {
  LedgerLayoutProbe: {
    section: "ledger",
    fields: {
      probe_realm: "efs.ledger.v2.realm",
      probe_counters: "efs.ledger.v2.counters",
      probe_records: "efs.ledger.v2.records",
      probe_subjects: "efs.ledger.v2.subjects",
      probe_admissions: "efs.ledger.v2.admissions",
      probe_publications: "efs.ledger.v2.publications",
      probe_bindings: "efs.ledger.v2.bindings",
      probe_principals: "efs.ledger.v2.principals",
      probe_revisions: "efs.ledger.v2.revisions",
    },
  },
  RegistryLayoutProbe: {
    section: "registry",
    fields: {
      probe_types: "efs.registry.v2.types",
      probe_declarations: "efs.registry.v2.declarations",
      probe_policy: "efs.registry.v2.policy",
      probe_roles: "efs.registry.v2.roles",
      probe_bindings: "efs.registry.v2.bindings",
      probe_wrappers: "efs.registry.v2.wrappers",
      probe_catalog: "efs.registry.v2.catalog",
      probe_control: "efs.registry.v2.control",
    },
  },
  PostingStoreLayoutProbe: { section: "index", fields: { probe_posting: "efs.index.v2.store.posting" } },
  BitmapStoreLayoutProbe: { section: "index", fields: { probe_bitmap: "efs.index.v2.store.bitmap" } },
  GenerationLayoutProbe: { section: "index", fields: { probe_gen: "efs.index.v2.gen" } },
};
// Reserved ledger namespaces and the transient lock have no struct; they are part of the manifest.
const RESERVED = { "efs.ledger.v2.source": "reserved (S4 SourceEvidence)", "efs.ledger.v2.staging": "reserved (stage-then-commit)" };
const LOCK = "efs.ledger.v2.lock";

const erc7201 = (id) => {
  const h = BigInt(keccak256(stringToHex(id)));
  return BigInt(keccak256(encodeAbiParameters([{ type: "uint256" }], [h - 1n]))) & ~0xffn;
};
const hex32 = (n) => toHex(n, { size: 32 });

const inspect = (probe) => {
  const r = spawnSync("forge", ["inspect", `test/harness/LayoutProbe.sol:${probe}`, "storageLayout", "--json"], { cwd: root, encoding: "utf8" });
  if (r.status !== 0) throw new Error(`forge inspect ${probe} failed:\n${r.stdout}${r.stderr}`);
  return JSON.parse(r.stdout);
};

// Canonical names: strip the solc type ids ("t_struct(RecordCell)123_storage" -> "RecordCell").
const structName = (t) => /t_struct\(([^)]+)\)/.exec(t)?.[1];
const solType = (t, types) => {
  if (t.startsWith("t_struct(")) return structName(t);
  const m = /^t_(uint\d+|int\d+|address|bool|bytes\d+)$/.exec(t);
  if (m) return m[1];
  return types[t].label;
};
const bits = (t, types) => Number(types[t].numberOfBytes) * 8;

// Flatten one struct type into fields (value members, nested structs inlined with a prefix),
// mappings and dynamic arrays, all with slots relative to the struct start.
function flatten(typeKey, types, prefix = "", baseSlot = 0n) {
  const out = { fields: [], mappings: [], arrays: [] };
  const ty = types[typeKey];
  for (const m of ty.members) {
    const name = prefix ? `${prefix}.${m.label}` : m.label;
    const slot = baseSlot + BigInt(m.slot);
    const mt = types[m.type];
    if (mt.encoding === "inplace" && m.type.startsWith("t_struct(")) {
      const inner = flatten(m.type, types, name, slot);
      out.fields.push(...inner.fields);
      out.mappings.push(...inner.mappings);
      out.arrays.push(...inner.arrays);
    } else if (mt.encoding === "inplace") {
      out.fields.push({ name, slot: Number(slot), offset: m.offset, bytes: Number(mt.numberOfBytes), type: solType(m.type, types) });
    } else if (mt.encoding === "mapping") {
      const keys = [];
      let v = m.type;
      while (types[v].encoding === "mapping") {
        keys.push(solType(types[v].key, types));
        v = types[v].value;
      }
      const value = types[v].encoding === "inplace" && v.startsWith("t_struct(") ? flatten(v, types) : null;
      out.mappings.push({ name, slot: Number(slot), keys, valueType: solType(v, types), valueBytes: Number(types[v].numberOfBytes), value });
    } else if (mt.encoding === "dynamic_array") {
      const base = mt.base;
      const elem = types[base].encoding === "inplace" && base.startsWith("t_struct(") ? flatten(base, types) : null;
      out.arrays.push({ name, slot: Number(slot), elemType: solType(base, types), elemBytes: Number(types[base].numberOfBytes), elem });
    } else {
      throw new Error(`unsupported encoding ${mt.encoding} at ${name}`);
    }
  }
  return out;
}

const manifest = { schema: "efs2/layout/1", namespaces: {} };
const raw = {};
for (const [probe, spec] of Object.entries(PROBES)) {
  const layout = inspect(probe);
  raw[probe] = layout;
  for (const entry of layout.storage) {
    const id = spec.fields[entry.label];
    if (!id) throw new Error(`${probe}: unexpected field ${entry.label}`);
    if (entry.offset !== 0) throw new Error(`${probe}.${entry.label} not slot-aligned`);
    const r = erc7201(id);
    const flat = flatten(entry.type, layout.types);
    manifest.namespaces[id] = { section: spec.section, root: hex32(r), struct: structName(entry.type), slots: Number(layout.types[entry.type].numberOfBytes) / 32, ...flat };
  }
}
for (const [id, note] of Object.entries(RESERVED)) manifest.namespaces[id] = { section: "ledger", root: hex32(erc7201(id)), reserved: note };
manifest.namespaces[LOCK] = { section: "ledger", root: hex32(erc7201(LOCK)), transient: true, fields: [
  { name: "phase", slot: 0, offset: 0, bytes: 1, type: "uint8" }, { name: "stagedPublication", slot: 0, offset: 1, bytes: 6, type: "uint48" },
  { name: "admissionFrontier", slot: 0, offset: 7, bytes: 6, type: "uint48" }, { name: "mutationsSnapshot", slot: 0, offset: 13, bytes: 6, type: "uint48" } ] };

// layoutId: keccak("efs2/ledger-layout/1" ‖ canonical JSON of the ledger section) — the identity the
// kernel implementation carries as LAYOUT_ID and every revision row records.
const canonical = (v) => JSON.stringify(v, (_, x) => (x && typeof x === "object" && !Array.isArray(x) ? Object.fromEntries(Object.keys(x).sort().map((k) => [k, x[k]])) : x));
const ledgerSection = Object.fromEntries(Object.entries(manifest.namespaces).filter(([, v]) => v.section === "ledger"));
manifest.layoutId = keccak256(stringToHex("efs2/ledger-layout/1" + canonical(ledgerSection)));

// ---- Solidity emission ---------------------------------------------------------------------------------
const C = (id) => id.replace(/^efs\./, "").replace(/\./g, "_").replace(/v2_/, "").toUpperCase(); // efs.ledger.v2.realm -> LEDGER_REALM
const fn = (id, name) => { const ns = id.replace(/^efs\.(ledger|registry|index)\.v2\.(store\.)?/, "").replace(/\./g, "_"); return ns + name[0].toUpperCase() + name.slice(1).replace(/\./g, "_"); };
const keyType = (k) => (k === "address" ? "address" : k);
const castOut = (f) => {
  const shift = f.offset * 8;
  const src = shift ? `x >> ${shift}` : "x";
  if (f.type === "address") return `address(uint160(${src}))`;
  if (f.type.startsWith("uint")) return f.bytes === 32 ? `uint256(${src})` : `${f.type}(${src})`;
  if (f.type.startsWith("bytes")) return `${f.type}(w)`;
  if (f.type === "bool") return `(${src}) & 1 == 1`;
  throw new Error(`cannot unpack ${f.type}`);
};
const lines = [];
const P = (s = "") => lines.push(s);
P("// SPDX-License-Identifier: MIT");
P("pragma solidity 0.8.37;");
P("");
P("// GENERATED by tools/layout.mjs from the compiler's storage layout of test/harness/LayoutProbe.sol.");
P("// Do not edit: run `pnpm layout` after changing a storage contract and commit the result together with");
P("// test/snapshots/layout/*.json and vectors/layout.json. Readers that have only raw slots (the facets, the");
P("// replay decoder, StateDigest, the SDK twin) derive every key and unpack every word through this library;");
P("// the kernel, delegates, registry and stores read their typed structs directly (the compiler packs them).");
P("// forge-lint: disable-start(unsafe-typecast)");
P("library Layout {");
P(`    bytes32 internal constant LAYOUT_ID = ${manifest.layoutId};`);
P("");
const emitted = new Set();
function emitStructUnpackers(prefix, flat) {
  // group fields by slot; one unpacker per slot that has more than one member or a non-32-byte member
  const bySlot = new Map();
  for (const f of flat.fields) { if (!bySlot.has(f.slot)) bySlot.set(f.slot, []); bySlot.get(f.slot).push(f); }
  for (const [slot, fields] of bySlot) {
    if (fields.length === 1 && fields[0].bytes === 32) continue;
    const name = `unpack${prefix}${bySlot.size > 1 ? "Word" + slot : ""}`;
    if (emitted.has(name)) continue;
    emitted.add(name);
    const rets = fields.map((f) => `${f.type} ${f.name.replace(/\./g, "_")}`).join(", ");
    P(`    // slot +${slot} of ${prefix}: ${fields.map((f) => `${f.name} at bit ${f.offset * 8}`).join(" | ")}`);
    P(`    function ${name}(bytes32 w) internal pure returns (${rets}) {`);
    P("        uint256 x = uint256(w);");
    for (const f of fields) P(`        ${f.name.replace(/\./g, "_")} = ${castOut(f)};`);
    P("    }");
    P("");
  }
}
for (const [id, ns] of Object.entries(manifest.namespaces)) {
  const NS = C(id);
  P(`    // ---- ${id}${ns.reserved ? " (" + ns.reserved + ")" : ns.transient ? " (transient)" : ` — ${ns.struct}, ${ns.slots} slot(s)`}`);
  P(`    bytes32 internal constant ${NS}_ROOT = ${ns.root};`);
  if (ns.reserved) { P(""); continue; }
  for (const f of ns.fields || []) {
    if (ns.transient) continue;
    P(`    uint256 internal constant ${NS}_${f.name.replace(/\./g, "_").toUpperCase()}_SLOT = uint256(${NS}_ROOT) + ${f.slot}; // ${f.type} @ byte ${f.offset}`);
  }
  for (const m of ns.mappings || []) {
    const args = m.keys.map((k, i) => `${keyType(k)} k${i}`).join(", ");
    P(`    // ${m.name}[${m.keys.join("][")}] -> ${m.valueType} (${m.valueBytes} bytes)`);
    P(`    function ${fn(id, m.name)}Slot(${args}) internal pure returns (uint256 s) {`);
    P(`        s = uint256(${NS}_ROOT) + ${m.slot};`);
    m.keys.forEach((k, i) => P(`        s = uint256(keccak256(abi.encode(k${i}, s)));`));
    P("    }");
    P("");
  }
  for (const a of ns.arrays || []) {
    const elemSlots = Math.ceil(a.elemBytes / 32);
    P(`    // ${a.name}: length at the slot, element i at keccak(slot) + i * ${elemSlots}`);
    P(`    uint256 internal constant ${NS}_${a.name.toUpperCase()}_LENGTH_SLOT = uint256(${NS}_ROOT) + ${a.slot};`);
    P(`    function ${fn(id, a.name)}ElementSlot(uint256 i) internal pure returns (uint256) {`);
    P(`        return uint256(keccak256(abi.encode(uint256(${NS}_ROOT) + ${a.slot}))) + i * ${elemSlots};`);
    P("    }");
    P("");
  }
  if (!ns.transient && ns.fields?.length) emitStructUnpackers(ns.struct, ns);
  for (const m of ns.mappings || []) if (m.value) emitStructUnpackers(m.valueType, m.value);
  for (const a of ns.arrays || []) if (a.elem) emitStructUnpackers(a.elemType, a.elem);
}
// the transient lock word
P("    // efs.ledger.v2.lock: phase at bit 0 | stagedPublication at 8 | admissionFrontier at 56 | mutationsSnapshot at 104");
P("    function unpackLock(bytes32 w) internal pure returns (uint8 phase, uint48 stagedPublication, uint48 admissionFrontier, uint48 mutationsSnapshot) {");
P("        uint256 x = uint256(w);");
P("        phase = uint8(x);");
P("        stagedPublication = uint48(x >> 8);");
P("        admissionFrontier = uint48(x >> 56);");
P("        mutationsSnapshot = uint48(x >> 104);");
P("    }");
P("}");
P("// forge-lint: disable-end(unsafe-typecast)");
const fmt = spawnSync("forge", ["fmt", "--raw", "-"], { cwd: root, encoding: "utf8", input: lines.join("\n") + "\n" });
if (fmt.status !== 0) throw new Error(`forge fmt --raw failed:\n${fmt.stderr}`);
const sol = fmt.stdout;
const json = JSON.stringify(manifest, null, 2) + "\n";

const outputs = { "src/core/layout/Layout.sol": sol, "vectors/layout.json": json };
// Snapshots omit `astId` (it shifts whenever any source is added) so the gate compares layout, not AST numbering.
const stable = (layout) => ({ ...layout, storage: layout.storage.map(({ astId, ...rest }) => rest) });
for (const [probe, layout] of Object.entries(raw)) outputs[`test/snapshots/layout/${probe}.json`] = JSON.stringify(stable(layout), null, 2) + "\n";
let dirty = 0;
for (const [path, content] of Object.entries(outputs)) {
  const abs = join(root, path);
  const current = existsSync(abs) ? readFileSync(abs, "utf8") : null;
  if (current === content) continue;
  dirty++;
  if (check) console.error(`layout: ${path} is out of date`);
  else { mkdirSync(dirname(abs), { recursive: true }); writeFileSync(abs, content); console.log(`layout: wrote ${path}`); }
}
console.log(`layout: ${Object.keys(manifest.namespaces).length} namespaces; layoutId ${manifest.layoutId}; ${dirty} file(s) ${check ? "differ" : "written"}`);
if (check && dirty) process.exit(1);
