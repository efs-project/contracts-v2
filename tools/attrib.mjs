// SPDX-License-Identifier: MIT
// Runtime-bytes attribution for one compiled contract (Node built-ins only).
//
//   node tools/attrib.mjs out/<File>.sol/<Contract>.json [--out out] [--json report.json] [--diff old.json] [--top N]
//
// Inputs are Foundry artifacts only: the target's deployedBytecode (object + sourceMap), methodIdentifiers
// and metadata; the `ast` of every artifact under --out (build with `forge build --ast` or
// FOUNDRY_PROFILE=ci, whose profile sets `ast = true`); and the build-info files forge writes beside them,
// which name the source id -> path table of the target's own compilation run.
//
// Method: decode the source map, walk the code into instructions, split basic blocks, and name each block
// by the AST definition (function, modifier, public-variable getter) that owns most of its bytes. Unnamed
// blocks (contract-level or compiler-generated code) get an owner by reachability over jump-tag pushes:
// one selector's wrapper, one named function's helper, the dispatcher, several owners (shared) or none
// (unreached). Bytes after the last mapped instruction are the trailer. Every byte lands in exactly one
// category and the report prints that reconciliation; a mismatch exits 1.
import { existsSync, readFileSync, readdirSync, statSync, writeFileSync } from "node:fs";
import { basename, join } from "node:path";
import { parseArgs } from "node:util";

const USAGE = "usage: node tools/attrib.mjs <out/File.sol/Contract.json> [--out <dir>] [--json <file>] [--diff <previous.json>] [--top N]";
const fail = (message, code = 2) => {
  console.error(`attrib: ${message}`);
  process.exit(code);
};

let opt, positionals;
try {
  ({ values: opt, positionals } = parseArgs({
    allowPositionals: true,
    options: {
      out: { type: "string", default: "out" },
      json: { type: "string" },
      diff: { type: "string" },
      top: { type: "string", default: "25" },
      help: { type: "boolean", short: "h" },
    },
  }));
} catch (e) {
  fail(`${e.message}\n${USAGE}`);
}
if (opt.help) {
  console.log(USAGE);
  process.exit(0);
}
if (positionals.length !== 1) fail(USAGE);
const top = Number(opt.top);
if (!Number.isInteger(top) || top < 0) fail("--top takes a non-negative integer (0 prints every row)");
const readJson = (path) => {
  try {
    return JSON.parse(readFileSync(path, "utf8"));
  } catch (e) {
    fail(`cannot read ${path}: ${e.message}`);
  }
};

// ---- Target artifact -------------------------------------------------------------------------------------
const artifactPath = positionals[0];
const art = readJson(artifactPath);
const runtime = art.deployedBytecode;
if (!runtime?.object || !runtime.sourceMap) fail(`${artifactPath}: no deployedBytecode.object / sourceMap`);
// Unlinked library placeholders (__$<34 hex>$__) are 20 bytes; zero them so the code still walks.
const hex = runtime.object.replace(/^0x/, "").replace(/__\$[0-9a-fA-F]{34}\$__/g, "0".repeat(40));
const code = Buffer.from(hex, "hex");
if (code.length === 0) fail(`${artifactPath}: empty runtime code (interface or abstract contract?)`);
const target = Object.entries(art.metadata?.settings?.compilationTarget ?? {})[0];
const targetPath = target?.[0] ?? art.ast?.absolutePath ?? null;
const contractName = target?.[1] ?? basename(artifactPath, ".json");
const contractId = targetPath ? `${targetPath}:${contractName}` : contractName;
const closure = art.metadata?.sources ? new Set(Object.keys(art.metadata.sources)) : null;
const warnings = [];

// ---- ASTs and build-info under --out ---------------------------------------------------------------------
if (!existsSync(opt.out) || !statSync(opt.out).isDirectory()) fail(`--out ${opt.out} is not a directory`);
const walk = (dir) =>
  readdirSync(dir, { withFileTypes: true }).flatMap((e) =>
    e.isDirectory() ? walk(join(dir, e.name)) : e.name.endsWith(".json") ? [join(dir, e.name)] : []);
const srcOf = (src) => {
  const [s, l, f] = src.split(":").map(Number);
  return { s, l, f };
};
const units = new Map(); // path -> { end, fileIndex, artifact, ranges, contracts }
const buildInfos = []; // { file, ids: Map<number, path>, mtime }
for (const file of walk(opt.out)) {
  let json;
  try {
    json = JSON.parse(readFileSync(file, "utf8"));
  } catch (e) {
    warnings.push(`${file}: skipped (${e.message})`);
    continue;
  }
  if (json.source_id_to_path) {
    buildInfos.push({ file, ids: new Map(Object.entries(json.source_id_to_path).map(([k, v]) => [Number(k), v])), mtime: statSync(file).mtimeMs });
    continue;
  }
  const unit = json.ast;
  if (unit?.nodeType !== "SourceUnit" || !unit.absolutePath) continue;
  const { s, l, f } = srcOf(unit.src); // ast.id is a node id; the source-map file index is src's third field
  const seen = units.get(unit.absolutePath);
  if (seen) {
    if (seen.end !== s + l) warnings.push(`${unit.absolutePath}: ASTs in ${seen.artifact} and ${file} differ in length (stale artifact?); using the first`);
    continue;
  }
  units.set(unit.absolutePath, { end: s + l, fileIndex: f, artifact: file, ...collect(unit) });
}
if (units.size === 0) fail(`no artifact under ${opt.out}/ carries an \`ast\`; rebuild with \`forge build --ast\` (or FOUNDRY_PROFILE=ci)`);

// Named ranges of one source unit. Definitions never nest (contracts hold functions; functions hold no
// definitions), so bodies are not descended into: a Yul function inside inline assembly stays with the
// enclosing Solidity function, and statements, events and errors fall to their enclosing definition.
function collect(unit) {
  const ranges = [];
  const contracts = [];
  const file = basename(unit.absolutePath);
  const add = (node, contract, name, kind) => {
    const { s, l } = srcOf(node.src);
    const params = node.parameters?.parameters?.map((p) => (p.typeDescriptions?.typeString ?? "?").replace(/ (?:memory|calldata|storage)(?: pointer| ref)?$/, "")) ?? [];
    ranges.push({ start: s, end: s + l, base: contract ? `${contract}.${name}` : `${file}:${name}`, params, kind, selector: node.functionSelector ?? null });
  };
  const visit = (node, contract) => {
    if (Array.isArray(node)) return node.forEach((n) => visit(n, contract));
    switch (node?.nodeType) {
      case "SourceUnit":
        return visit(node.nodes, null);
      case "ContractDefinition": {
        const { s, l } = srcOf(node.src);
        contracts.push({ start: s, end: s + l, name: node.name });
        return visit(node.nodes, node.name);
      }
      case "FunctionDefinition":
        return add(node, contract, ["constructor", "fallback", "receive"].includes(node.kind) ? node.kind : node.name, node.kind === "function" || node.kind === "freeFunction" ? "function" : node.kind);
      case "ModifierDefinition":
        return add(node, contract, node.name, "modifier");
      case "VariableDeclaration":
        if (node.stateVariable && node.functionSelector) add(node, contract, node.name, "getter");
        return;
      default:
        return;
    }
  };
  visit(unit, null);
  ranges.sort((a, b) => a.start - b.start);
  contracts.sort((a, b) => a.start - b.start);
  return { ranges, contracts };
}

// Labels: `Contract.name`, or `File.sol:name` for free functions; overloads get their parameter types.
// Only the target's own sources count, so unrelated artifacts under --out never change a label.
{
  for (const u of units.values()) for (const r of u.ranges) r.label = r.base;
  const relevant = [...units].filter(([path]) => !closure || closure.has(path));
  const byBase = new Map();
  for (const [, u] of relevant) for (const r of u.ranges) byBase.set(r.base, (byBase.get(r.base) ?? 0) + 1);
  const taken = new Set();
  for (const [path, u] of relevant) {
    for (const r of u.ranges) {
      r.label = byBase.get(r.base) > 1 ? `${r.base}(${r.params.join(",")})` : r.base;
      if (taken.has(r.label)) r.label = `${r.label} [${path}]`;
      taken.add(r.label);
    }
  }
}

// Source id -> path for the target's compilation run. Source ids are per run, and forge keeps artifacts of
// files it did not recompile, so an AST's own file index can be stale. Prefer the build-info whose table
// places the target at the target artifact's id; fall back to AST indices restricted to the target closure.
const idToPath = new Map();
let mapping;
{
  const fits = buildInfos.filter((b) => {
    const paths = new Set(b.ids.values());
    return targetPath && b.ids.get(art.id) === targetPath && (!closure || [...closure].every((p) => paths.has(p)));
  });
  fits.sort((a, b) => b.mtime - a.mtime);
  if (fits.length > 0) {
    for (const [id, path] of fits[0].ids) idToPath.set(id, path);
    mapping = `build-info ${basename(fits[0].file, ".json")}`;
    if (fits.length > 1) warnings.push(`${fits.length} build-info files fit the target; using the newest (${fits[0].file})`);
    for (const [path, u] of units) {
      if (closure && !closure.has(path)) continue;
      if (idToPath.get(u.fileIndex) !== path) warnings.push(`${path}: its AST carries file index ${u.fileIndex} from another compilation run; ranges are still used, the id comes from build-info`);
    }
  } else {
    mapping = "AST file indices (no matching build-info)";
    const claims = new Map();
    for (const [path, u] of units) if (!closure || closure.has(path)) claims.set(u.fileIndex, [...(claims.get(u.fileIndex) ?? []), path]);
    for (const [id, paths] of claims) {
      if (paths.length === 1) idToPath.set(id, paths[0]);
      else warnings.push(`file index ${id} is claimed by ${paths.join(", ")} (stale artifacts from different runs); its bytes stay unresolved`);
    }
  }
  if (closure) for (const path of closure) if (!units.has(path)) warnings.push(`${path}: no artifact AST; its bytes count as unresolved`);
}

// ---- Source map and instructions -------------------------------------------------------------------------
const entries = [];
{
  let prev = [0, 0, -1, "-", 0];
  for (const item of runtime.sourceMap.split(";")) {
    const cur = prev.slice();
    item.split(":").forEach((p, i) => {
      if (p !== "" && i < 5) cur[i] = i === 3 ? p : Number(p);
    });
    entries.push(cur);
    prev = cur;
  }
}
const isPush = (op) => op >= 0x60 && op <= 0x7f;
const ins = { pc: [], size: [], op: [], imm: [], entry: [] }; // imm: value of PUSH1..PUSH6 (else -1)
let mappedEnd = 0;
for (let pc = 0, i = 0; pc < code.length && i < entries.length; i++) {
  const op = code[pc];
  const n = isPush(op) ? op - 0x5e : 1;
  ins.pc.push(pc);
  ins.size.push(n);
  ins.op.push(op);
  ins.imm.push(isPush(op) && n <= 7 ? code.subarray(pc + 1, pc + n).reduce((v, b) => v * 256 + b, 0) : -1);
  ins.entry.push(entries[i]);
  pc += n;
  mappedEnd = Math.min(pc, code.length);
}
const count = ins.pc.length;
if (count < entries.length) warnings.push(`source map has ${entries.length} entries but the code holds ${count} instructions`);

// Resolve each source location to a named definition, contract-level code, or nothing.
const coverage = { named: 0, contract: 0, file: 0, generated: 0, unmapped: 0, noast: 0 };
const outOfRange = new Map();
const memo = new Map();
const locate = ([s, l, f]) => {
  const key = `${s}:${l}:${f}`;
  if (memo.has(key)) return memo.get(key);
  let hit;
  const path = f >= 0 ? idToPath.get(f) : undefined;
  const unit = path && units.get(path);
  if (f < 0) hit = { cls: "unmapped" };
  else if (!path) hit = { cls: "generated" }; // ids past the source list are compiler-generated Yul sources
  else if (!unit) hit = { cls: "noast" };
  else {
    if (s + l > unit.end) outOfRange.set(path, (outOfRange.get(path) ?? 0) + 1);
    const inside = (list) => {
      let lo = 0;
      let hi = list.length - 1;
      let best = -1;
      while (lo <= hi) {
        const mid = (lo + hi) >> 1;
        if (list[mid].start <= s) (best = mid), (lo = mid + 1);
        else hi = mid - 1;
      }
      return best >= 0 && s + l <= list[best].end ? list[best] : null;
    };
    const range = inside(unit.ranges);
    hit = range ? { cls: "named", label: range.label, range } : inside(unit.contracts) ? { cls: "contract" } : { cls: "file" };
  }
  memo.set(key, hit);
  return hit;
};
const where = ins.entry.map(locate);
const unresolvedIds = new Map(); // file index -> bytes, for ids with no path in the chosen table
for (let i = 0; i < count; i++) {
  coverage[where[i].cls] += ins.size[i];
  if (where[i].cls === "generated") unresolvedIds.set(ins.entry[i][2], (unresolvedIds.get(ins.entry[i][2]) ?? 0) + ins.size[i]);
}
// With build-info, ids past the table are compiler-generated sources. Without it they may also be ids a
// stale AST no longer claims, so name them.
if (!mapping.startsWith("build-info") && unresolvedIds.size) warnings.push(`file indices with no AST path in the target closure (generated sources, or stale ids from another run): ${[...unresolvedIds].map(([id, n]) => `${id} (${n} bytes)`).join(", ")}`);
for (const [path, n] of outOfRange) warnings.push(`${path}: ${n} source locations end past the AST's length; the id mapping or the AST is stale`);
const rangeOf = new Map();
for (const w of where) if (w.range) rangeOf.set(w.label, w.range);

// ---- Basic blocks and successors -------------------------------------------------------------------------
const TERMINATES = new Set([0x00, 0x56, 0x57, 0xf3, 0xfd, 0xfe, 0xff]); // STOP JUMP JUMPI RETURN REVERT INVALID SELFDESTRUCT
const NO_FALLTHROUGH = new Set([0x00, 0x56, 0xf3, 0xfd, 0xfe, 0xff]);
const blocks = []; // { first, last, start, bytes }
for (let i = 0, first = 0; i < count; i++) {
  if (ins.op[i] === 0x5b && i > first) {
    blocks.push({ first, last: i - 1 });
    first = i;
  }
  if (TERMINATES.has(ins.op[i]) || i === count - 1) {
    blocks.push({ first, last: i });
    first = i + 1;
  }
}
for (const b of blocks) {
  b.start = ins.pc[b.first];
  b.bytes = ins.pc[b.last] + ins.size[b.last] - b.start;
}
const blockAt = new Map(); // JUMPDEST pc -> block index
blocks.forEach((b, bi) => ins.op[b.first] === 0x5b && blockAt.set(b.start, bi));
// Solc pushes every jump tag with one width; take the commonest PUSHk directly before a JUMP/JUMPI.
let tagWidth;
{
  const widths = new Map();
  for (let i = 1; i < count; i++) {
    if ((ins.op[i] === 0x56 || ins.op[i] === 0x57) && isPush(ins.op[i - 1]) && blockAt.has(ins.imm[i - 1])) widths.set(ins.size[i - 1] - 1, (widths.get(ins.size[i - 1] - 1) ?? 0) + 1);
  }
  tagWidth = [...widths].sort((a, b) => b[1] - a[1])[0]?.[0] ?? Math.max(1, Math.ceil(Math.log2(code.length + 1) / 8));
}
const isTag = (i) => ins.size[i] === tagWidth + 1 && isPush(ins.op[i]) && blockAt.has(ins.imm[i]);
// Successors: every pushed tag (jump targets, return addresses, function pointers) plus fallthrough.
const succ = blocks.map((b, bi) => {
  const out = new Set();
  for (let i = b.first; i <= b.last; i++) if (isTag(i)) out.add(blockAt.get(ins.imm[i]));
  if (!NO_FALLTHROUGH.has(ins.op[b.last]) && bi + 1 < blocks.length) out.add(bi + 1);
  return [...out];
});
// Block name: the definition owning most of the block's named bytes; ties go to the first seen. Only
// instructions that resolve to a definition vote: a location spanning the whole contract or no source at
// all (-1) says nothing about the function, and via-IR emits most of a function's code that way. A block
// with no named instruction stays unnamed (null) and is owned by reachability below.
const names = blocks.map((b) => {
  const bytes = new Map();
  for (let i = b.first; i <= b.last; i++) if (where[i].label) bytes.set(where[i].label, (bytes.get(where[i].label) ?? 0) + ins.size[i]);
  let best = null;
  let most = -1;
  for (const [label, n] of bytes) if (n > most) (best = label), (most = n);
  return best;
});

// ---- Dispatcher: PUSH selector, [DUP/SWAP], EQ (or SUB/XOR), [ISZERO]*, PUSH tag, JUMPI --------------------
const selectorOf = new Map(Object.entries(art.methodIdentifiers ?? {}).map(([sig, sel]) => [parseInt(sel, 16), sig]));
const entry = new Map(); // signature -> block index
const blockOfIns = new Int32Array(count);
blocks.forEach((b, bi) => blockOfIns.fill(bi, b.first, b.last + 1));
for (let i = 0; i < count; i++) {
  if (!(ins.op[i] >= 0x60 && ins.op[i] <= 0x63) || !selectorOf.has(ins.imm[i])) continue;
  let k = i + 1;
  while (k < count && k <= i + 3 && ins.op[k] >= 0x80 && ins.op[k] <= 0x9f) k++;
  let jumpsOnMatch;
  if (ins.op[k] === 0x14) jumpsOnMatch = true;
  else if (ins.op[k] === 0x03 || ins.op[k] === 0x18) jumpsOnMatch = false;
  else continue;
  for (k++; ins.op[k] === 0x15; k++) jumpsOnMatch = !jumpsOnMatch;
  if (k + 1 >= count || !isTag(k) || ins.op[k + 1] !== 0x57) continue;
  const target = jumpsOnMatch ? blockAt.get(ins.imm[k]) : k + 2 < count ? blockOfIns[k + 2] : undefined;
  const sig = selectorOf.get(ins.imm[i]);
  if (target !== undefined && !entry.has(sig)) entry.set(sig, target);
}
const missing = [...selectorOf.values()].filter((sig) => !entry.has(sig));
if (missing.length) warnings.push(`selectors not found in a dispatcher comparison (their wrappers count as unreached/shared): ${missing.join(", ")}`);

// ---- Ownership by reachability ---------------------------------------------------------------------------
// reach() returns the blocks it expands; a stopped block is touched but not owned.
const reach = (starts, stop, touched) => {
  const seen = new Set();
  const stack = [...starts];
  while (stack.length) {
    const b = stack.pop();
    if (seen.has(b)) continue;
    if (stop(b)) {
      touched?.add(names[b]);
      continue;
    }
    seen.add(b);
    for (const s of succ[b]) stack.push(s);
  }
  return seen;
};
const owners = blocks.map(() => ({ sels: new Set(), fns: new Set(), dispatcher: false }));
const implementation = new Map(); // signature -> label
const entryBlocks = new Set(entry.values());
for (const [sig, start] of entry) {
  const touched = new Set();
  for (const b of reach([start], (b) => b !== start && names[b] !== null, touched)) if (names[b] === null) owners[b].sels.add(sig);
  if (names[start] !== null) touched.add(names[start]);
  const sel = art.methodIdentifiers[sig];
  const impl = [...touched].filter((label) => rangeOf.get(label)?.selector === sel);
  if (impl.length === 1) implementation.set(sig, impl[0]);
}
const fnBlocks = new Map();
names.forEach((label, b) => label !== null && (fnBlocks.get(label) ?? fnBlocks.set(label, []).get(label)).push(b));
for (const [label, starts] of fnBlocks) {
  for (const b of reach(starts, (b) => names[b] !== null && names[b] !== label)) if (names[b] === null) owners[b].fns.add(label);
}
if (blocks.length) {
  for (const b of reach([0], (b) => b !== 0 && (names[b] !== null || entryBlocks.has(b)))) if (names[b] === null) owners[b].dispatcher = true;
}

const functions = new Map(); // label -> { named, helpers }
const fnRow = (label) => functions.get(label) ?? functions.set(label, { named: 0, helpers: 0 }).get(label);
const selectors = new Map([...entry.keys()].map((sig) => [sig, 0]));
let shared = 0;
let unreached = 0;
let dispatcher = 0;
const sharedBlocks = [];
blocks.forEach((b, bi) => {
  if (names[bi] !== null) return void (fnRow(names[bi]).named += b.bytes);
  const { sels, fns, dispatcher: disp } = owners[bi];
  const [fn] = fns;
  if (!disp && fns.size === 1 && [...sels].every((sig) => implementation.get(sig) === fn)) fnRow(fn).helpers += b.bytes;
  else if (!disp && fns.size === 0 && sels.size === 1) selectors.set([...sels][0], selectors.get([...sels][0]) + b.bytes);
  else if (disp && fns.size === 0 && sels.size === 0) dispatcher += b.bytes;
  else if (!disp && fns.size === 0 && sels.size === 0) unreached += b.bytes;
  else (shared += b.bytes), sharedBlocks.push({ pc: b.start, bytes: b.bytes, owners: sels.size + fns.size + (disp ? 1 : 0) });
});
const trailer = code.length - mappedEnd;
const cborLength = code.length >= 2 ? code.readUInt16BE(code.length - 2) + 2 : 0;
const cbor = cborLength <= trailer && (code[code.length - cborLength] & 0xe0) === 0xa0 ? cborLength : 0;
if (!cbor) warnings.push("no CBOR metadata trailer recognised in the bytes after the last mapped instruction");

// ---- Report ----------------------------------------------------------------------------------------------
const sum = (it) => [...it].reduce((a, b) => a + b, 0);
const fnTotal = (r) => r.named + r.helpers;
const byBytes = (a, b) => b[1] - a[1] || (a[0] < b[0] ? -1 : 1);
const fnSorted = [...functions].map(([label, r]) => [label, fnTotal(r), r]).sort(byBytes);
const selSorted = [...selectors].sort(byBytes);
const functionBytes = sum(fnSorted.map((r) => r[1]));
const selectorBytes = sum(selSorted.map((r) => r[1]));
const total = functionBytes + selectorBytes + shared + unreached + dispatcher + trailer;
const blockBytes = sum(blocks.map((b) => b.bytes));
const reconciled = total === code.length && blockBytes === mappedEnd;
const pct = (n) => `${((100 * n) / code.length).toFixed(1).padStart(5)}%`;
const hexPc = (pc) => `0x${pc.toString(16).padStart(4, "0")}`;
const kindTag = (label) => ({ modifier: " [modifier]", getter: " [getter]", constructor: " [constructor]", fallback: " [fallback]", receive: " [receive]" })[rangeOf.get(label)?.kind] ?? "";
const limit = (rows) => (top === 0 ? rows : rows.slice(0, top));
const rest = (rows, value) => {
  if (top === 0 || rows.length <= top) return;
  const left = rows.slice(top);
  console.log(`  ... ${left.length} more row${left.length === 1 ? "" : "s"}, ${sum(left.map(value))} bytes (--top 0 prints all)`);
};
const width = Math.max(40, ...fnSorted.map((r) => r[0].length + kindTag(r[0]).length), ...selSorted.map((r) => r[0].length)) + 2;

console.log(`attrib: ${contractId}  (${artifactPath})`);
console.log(`runtime ${code.length} bytes (EIP-170 headroom ${24576 - code.length}); ${count} instructions over ${mappedEnd} mapped bytes; ${blocks.length} basic blocks; tags PUSH${tagWidth}`);
const resolved = [...idToPath.values()].filter((p) => units.has(p)).length;
console.log(`source ids: ${mapping}; ${resolved}/${idToPath.size} ids with an AST; ${units.size} ASTs scanned under ${opt.out}/`);
console.log(`source-map coverage: named ${pct(coverage.named).trim()} | contract-level ${pct(coverage.contract + coverage.file).trim()} | generated ${pct(coverage.generated).trim()} | unmapped ${pct(coverage.unmapped).trim()}${coverage.noast ? ` | no AST ${pct(coverage.noast).trim()}` : ""} (of runtime bytes)`);
console.log(`dispatcher: ${entry.size}/${selectorOf.size} selectors located${entry.size ? `, entries ${hexPc(Math.min(...[...entry.values()].map((b) => blocks[b].start)))}..${hexPc(Math.max(...[...entry.values()].map((b) => blocks[b].start)))}` : ""}`);

console.log(`\nfunctions: named blocks + exclusively owned helper blocks`);
console.log(`  ${"".padEnd(width)}${"bytes".padStart(7)}${"named".padStart(7)}${"helper".padStart(7)}`);
for (const [label, n, r] of limit(fnSorted)) console.log(`  ${(label + kindTag(label)).padEnd(width)}${String(n).padStart(7)}${String(r.named).padStart(7)}${String(r.helpers).padStart(7)} ${pct(n)}`);
rest(fnSorted, (r) => r[1]);
console.log(`  ${"total".padEnd(width)}${String(functionBytes).padStart(7)}${"".padStart(14)} ${pct(functionBytes)}`);

const byContract = new Map();
for (const [label, n] of fnSorted) {
  const owner = label.split(/[.:]/)[0];
  byContract.set(owner, (byContract.get(owner) ?? 0) + n);
}
if (byContract.size) console.log(`  by defining contract: ${[...byContract].sort(byBytes).map(([c, n]) => `${c} ${n}`).join(" | ")}`);

console.log(`\nselectors: exclusive ABI wrapper bytes (contract-level blocks only that selector reaches)`);
for (const [sig, n] of limit(selSorted)) console.log(`  ${sig.padEnd(width)}${String(n).padStart(7)}  ${art.methodIdentifiers[sig]} @${hexPc(blocks[entry.get(sig)].start)} -> ${implementation.get(sig) ?? "?"}`);
rest(selSorted, (r) => r[1]);
console.log(`  ${"total".padEnd(width)}${String(selectorBytes).padStart(7)} ${pct(selectorBytes)}`);

sharedBlocks.sort((a, b) => b.bytes - a.bytes || a.pc - b.pc);
console.log(`\nother`);
console.log(`  ${"shared (blocks with several owners)".padEnd(width)}${String(shared).padStart(7)} ${pct(shared)}  ${sharedBlocks.length} blocks${sharedBlocks.length ? `; largest ${sharedBlocks.slice(0, 4).map((b) => `${b.bytes} B @${hexPc(b.pc)} (${b.owners} owners)`).join(", ")}` : ""}`);
console.log(`  ${"unreached (no owner found)".padEnd(width)}${String(unreached).padStart(7)} ${pct(unreached)}`);
console.log(`  ${"dispatcher prefix (reached only from pc 0)".padEnd(width)}${String(dispatcher).padStart(7)} ${pct(dispatcher)}`);
console.log(`  ${"trailer (after the last mapped instruction)".padEnd(width)}${String(trailer).padStart(7)} ${pct(trailer)}  CBOR ${cbor} + embedded data ${trailer - cbor}`);

console.log(`\nreconciliation: functions ${functionBytes} + selectors ${selectorBytes} + shared ${shared} + unreached ${unreached} + dispatcher ${dispatcher} + trailer ${trailer} = ${total} ${total === code.length ? "==" : "!="} runtime ${code.length}; blocks ${blockBytes} ${blockBytes === mappedEnd ? "==" : "!="} mapped ${mappedEnd}  ${reconciled ? "OK" : "MISMATCH"}`);
for (const w of warnings) console.log(`warning: ${w}`);

const report = {
  contract: contractId,
  runtimeBytes: code.length,
  functions: Object.fromEntries(fnSorted.map(([label, n]) => [label, n])),
  selectors: Object.fromEntries(selSorted),
  shared,
  unreached,
  dispatcherPrefix: dispatcher,
  trailer,
  detail: {
    mappedBytes: mappedEnd,
    instructions: count,
    blocks: blocks.length,
    tagWidth,
    cborBytes: cbor,
    embeddedDataBytes: trailer - cbor,
    sourceIds: mapping,
    coverage,
    functions: Object.fromEntries(fnSorted.map(([label, , r]) => [label, { named: r.named, helpers: r.helpers, kind: rangeOf.get(label)?.kind ?? null }])),
    selectors: Object.fromEntries(selSorted.map(([sig]) => [sig, { selector: art.methodIdentifiers[sig], entry: blocks[entry.get(sig)].start, implementation: implementation.get(sig) ?? null }])),
    missingSelectors: missing,
    warnings,
  },
};
if (opt.json) {
  writeFileSync(opt.json, `${JSON.stringify(report, null, 2)}\n`);
  console.log(`wrote ${opt.json}`);
}

// ---- Diff against a previous JSON report -----------------------------------------------------------------
if (opt.diff) {
  const prev = readJson(opt.diff);
  console.log(`\ndiff vs ${opt.diff}${prev.contract !== report.contract ? ` (contract ${prev.contract} -> ${report.contract})` : ""}`);
  const signed = (n) => (n > 0 ? `+${n}` : String(n));
  const scalars = ["runtimeBytes", "shared", "unreached", "dispatcherPrefix", "trailer"];
  console.log(`  ${scalars.map((k) => `${k} ${prev[k] ?? 0} -> ${report[k]} (${signed(report[k] - (prev[k] ?? 0))})`).join("; ")}`);
  const rows = [];
  for (const [section, prefix] of [["functions", ""], ["selectors", "selector "]]) {
    const a = prev[section] ?? {};
    const b = report[section];
    for (const key of new Set([...Object.keys(a), ...Object.keys(b)])) {
      if (a[key] === b[key]) continue;
      const status = !(key in a) ? "added" : !(key in b) ? "removed" : "changed";
      rows.push({ name: prefix + key, status, from: a[key] ?? 0, to: b[key] ?? 0, delta: (b[key] ?? 0) - (a[key] ?? 0) });
    }
  }
  rows.sort((x, y) => Math.abs(y.delta) - Math.abs(x.delta) || (x.name < y.name ? -1 : 1));
  for (const r of limit(rows)) console.log(`  ${r.status.padEnd(8)}${signed(r.delta).padStart(7)}  ${r.name}  (${r.from} -> ${r.to})`);
  rest(rows, (r) => r.delta);
  const tally = (s) => rows.filter((r) => r.status === s).length;
  console.log(`  ${rows.length} deltas: ${tally("added")} added, ${tally("removed")} removed, ${tally("changed")} changed; net ${signed(sum(rows.map((r) => r.delta)))} bytes`);
}
if (!reconciled) process.exit(1);
