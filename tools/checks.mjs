// SPDX-License-Identifier: MIT
// Contributor policy checks (Node built-ins only). Run with `pnpm check` from the repository root.
//
// What this gate asserts, and why:
//   - pinned Node and Foundry so build identity is reproducible;
//   - the compiler identity policy (D1): solc 0.8.37, EVM prague, `bytecode_hash = "none"` with the
//     CBOR trailer kept, so a rule's codehash (and therefore a Type id) never changes because a comment,
//     a path or a remapping changed;
//   - every original Solidity and tooling source carries the MIT SPDX header;
//   - dependency pins in soldeer.lock match the documented versions and their licenses are retained;
//   - the import direction between src/ layers (core/layout/ may be imported only by core/, control/, index/
//     and the two read facets; the consumer closure imports only itself);
//   - raw-slot reads (extsload/exttload) forbidden in profiles/, periphery/ and non-facet readers;
//   - opcode lints over the built ingress (zero-write) and apply (no external call) artifacts, when present;
//   - profile rules carry no immutable references (identical Type ids on every Realm).
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { existsSync, readFileSync, readdirSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const read = (path) => readFileSync(join(root, path), "utf8");
const stripComments = (src) => src.replace(/\/\*[\s\S]*?\*\//g, "").replace(/\/\/.*$/gm, "");
const pinnedNode = read(".node-version").trim();
assert.equal(process.versions.node, pinnedNode, "use the pinned Node runtime for contributor tooling");

const command = (args) => {
  const r = spawnSync("forge", args, { cwd: root, encoding: "utf8" });
  if (r.error) throw r.error;
  assert.equal(r.status, 0, `forge ${args.join(" ")}\n${r.stdout}${r.stderr}`);
  return r.stdout;
};
const forgeVersion = command(["--version"]).split("\n")[0].trim();
assert.equal(forgeVersion, `forge Version: ${read(".foundry-version").trim()}`);
const config = JSON.parse(command(["config", "--json"]));
assert.equal(config.solc, "0.8.37");
assert.equal(config.evm_version, "prague");
assert.equal(config.bytecode_hash, "none", "identity policy D1: no metadata hash in runtime bytes");
assert.equal(config.cbor_metadata, true, "identity policy D1: keep the 3-byte solc version trailer");
assert.equal(config.via_ir, true);
assert.equal(config.optimizer_runs, 200);

const files = (dir) =>
  existsSync(join(root, dir))
    ? readdirSync(join(root, dir), { withFileTypes: true }).flatMap((e) =>
        e.isDirectory() ? files(`${dir}/${e.name}`) : [`${dir}/${e.name}`])
    : [];

// SPDX headers on every original source. Vendored third-party code must live under src/periphery/vendor/
// with its own license files and is exempt here.
const original = [...files("src"), ...files("test"), ...files("script"), ...files("tools"), ...files("examples")]
  .filter((p) => /\.(?:mjs|sol)$/.test(p) && !p.startsWith("src/periphery/vendor/"));
for (const path of original) {
  assert.ok(read(path).startsWith("// SPDX-License-Identifier: MIT"), `${path}: missing MIT SPDX header`);
}

// Dependency pins and retained licenses.
const pins = {
  "forge-std": "1.17.0",
  "@openzeppelin-contracts": "5.6.1",
  "@openzeppelin-contracts-upgradeable": "5.6.1",
};
const lock = read("soldeer.lock");
for (const [name, version] of Object.entries(pins)) {
  assert.match(lock, new RegExp(`name = "${name.replace(/[-/\\^$*+?.()|[\]{}]/g, "\\$&")}"\\s+version = "${version.replace(/\./g, "\\.")}"`), `${name} ${version} missing from soldeer.lock`);
  const notices = read("THIRD_PARTY_NOTICES.md");
  assert.ok(notices.includes(`${name}`) && notices.includes(version), `THIRD_PARTY_NOTICES.md must name ${name} ${version}`);
}
assert.ok(existsSync(join(root, "dependencies/forge-std-1.17.0/LICENSE-MIT")));
assert.ok(existsSync(join(root, "dependencies/forge-std-1.17.0/LICENSE-APACHE")));
assert.ok(existsSync(join(root, "licenses/openzeppelin-contracts-5.6.1-LICENSE.txt")));
assert.ok(existsSync(join(root, "licenses/openzeppelin-contracts-upgradeable-5.6.1-LICENSE.txt")));

// Import direction inside src/ (periphery -> profiles -> readers -> {core,types,index} -> lib -> interfaces).
// interfaces/ and lib/ import nothing else from src/; the consumer closure (interfaces + lib) stays free of
// OpenZeppelin and transient storage; readers and index never import core/; nothing in src/ imports test code.
const layer = (p) => p.split("/")[1];
const rank = { interfaces: 0, lib: 1, core: 2, types: 2, index: 2, control: 2, readers: 3, profiles: 4, periphery: 5 };
const closure = new Set(["interfaces", "lib"]);
for (const path of files("src").filter((p) => p.endsWith(".sol") && !p.startsWith("src/periphery/vendor/"))) {
  const source = read(path);
  const from = layer(path);
  if (!(from in rank)) continue;
  for (const m of source.matchAll(/import\s+(?:[^"';]*?from\s+)?["']([^"']+)["']/g)) {
    const target = m[1];
    assert.ok(!/forge-std|\/test\/|examples\//.test(target), `${path} imports test or example code (${target})`);
    if (closure.has(from)) {
      assert.ok(!/openzeppelin/.test(target), `${path}: the consumer closure must not depend on OpenZeppelin`);
    }
    const resolved = target.startsWith(".") ? resolve(dirname(path), target).replace(root + "/", "") : null;
    if (resolved && resolved.startsWith("src/")) {
      const to = layer(resolved);
      assert.ok(to in rank, `${path} imports unknown layer ${to}`);
      assert.ok(rank[to] <= rank[from], `${path} (${from}) must not import ${resolved} (${to})`);
      if (to === "core") {
        const isLayout = resolved.startsWith("src/core/layout/");
        const layoutImporters = ["core", "control", "index"];
        const facet = /^src\/readers\/(LedgerReads|LedgerViews)\.sol$/.test(path);
        if (isLayout) assert.ok(layoutImporters.includes(from) || facet, `${path}: only core/, control/, index/ and the two facets may import core/layout/`);
        else assert.ok(["core", "control"].includes(from), `${path}: only core/ and control/ may import core/ (except core/layout/)`);
      }
      if (closure.has(from)) assert.ok(closure.has(to), `${path}: the consumer closure imports outside itself`);
    }
  }
  if (closure.has(from)) assert.ok(!/\btransient\b|\btstore\(|\btload\(/.test(stripComments(source)), `${path}: the consumer closure must not use transient storage`);
}

// Raw-slot reads are the proof-able floor for the two facets, the index, the decoder and the SDK — and
// forbidden in profiles/ and in every other reader (design §5.3, decision 30).
for (const path of files("src").filter((p) => p.endsWith(".sol"))) {
  const facet = /^src\/readers\/(LedgerReads|LedgerViews)\.sol$/.test(path);
  const banned = path.startsWith("src/profiles/") || (path.startsWith("src/readers/") && !facet) || path.startsWith("src/periphery/");
  if (banned) assert.ok(!/\bextsload(Batch)?\s*\(|\bexttload\s*\(/.test(stripComments(read(path))), `${path}: extsload/exttload are forbidden here (read the Etched hot getters or the facets)`);
}

// Opcode lints over built artifacts (design I3, §3.1 row 2): the zero-write ingress and the apply delegate.
// Push data and the CBOR trailer named by the last two bytes are skipped, like CodeScan on chain.
const forbiddenIn = {
  "out/LedgerIngress.sol/LedgerIngress.json": { SSTORE: 0x55, TSTORE: 0x5d, CREATE: 0xf0, CALLCODE: 0xf2, DELEGATECALL: 0xf4, CREATE2: 0xf5, SELFDESTRUCT: 0xff },
  "out/LedgerApply.sol/LedgerApply.json": { CREATE: 0xf0, CALL: 0xf1, CALLCODE: 0xf2, DELEGATECALL: 0xf4, CREATE2: 0xf5, STATICCALL: 0xfa, SELFDESTRUCT: 0xff },
};
const pendingLints = [];
for (const [artifact, forbidden] of Object.entries(forbiddenIn)) {
  if (!existsSync(join(root, artifact))) { pendingLints.push(artifact); continue; }
  const code = Buffer.from(JSON.parse(read(artifact)).deployedBytecode.object.replace(/^0x/, ""), "hex");
  const trailer = code.length >= 2 ? code.readUInt16BE(code.length - 2) + 2 : 0;
  const end = trailer <= code.length ? code.length - trailer : code.length;
  const byName = Object.fromEntries(Object.entries(forbidden).map(([n, op]) => [op, n]));
  for (let pc = 0; pc < end; pc++) {
    const op = code[pc];
    if (op >= 0x60 && op <= 0x7f) { pc += op - 0x5f; continue; }
    assert.ok(!(op in byName), `${artifact}: forbidden opcode ${byName[op]} at pc ${pc}`);
  }
}

// Profile rules carry no immutables, so their Type ids are identical on every Realm and chain (design §5.10).
const profileArtifacts = files("out").filter((p) => /\.json$/.test(p) && !p.includes("build-info"));
let profilesChecked = 0;
for (const path of profileArtifacts) {
  let art;
  try { art = JSON.parse(read(path)); } catch { continue; }
  const target = art?.metadata?.settings?.compilationTarget;
  const src = art?.ast?.absolutePath ?? (target ? Object.keys(target)[0] : undefined);
  if (!src || !String(src).startsWith("src/profiles/")) continue;
  profilesChecked++;
  const refs = art.deployedBytecode?.immutableReferences ?? {};
  assert.deepEqual(refs, {}, `${path}: a profile rule must have no immutable references`);
}

const sources = files("src").filter((p) => p.endsWith(".sol")).length;
console.log(`checks: Node ${process.versions.node}; ${forgeVersion}; solc ${config.solc}; EVM ${config.evm_version}; bytecode_hash ${config.bytecode_hash}`);
console.log(`checks: ${sources} production Solidity sources; ${original.length} original sources with MIT headers; pins ${Object.entries(pins).map(([n, v]) => `${n}@${v}`).join(", ")}`);
console.log(`checks: opcode lints ${Object.keys(forbiddenIn).length - pendingLints.length} run, ${pendingLints.length} pending (${pendingLints.map((a) => a.split("/")[1]).join(", ") || "none"}); ${profilesChecked} profile artifacts checked for immutables`);
