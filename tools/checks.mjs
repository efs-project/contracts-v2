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
//   - the import direction between src/ layers (added together with the first production sources).
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { existsSync, readFileSync, readdirSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const read = (path) => readFileSync(join(root, path), "utf8");
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
      if (to === "core") assert.ok(["core", "control"].includes(from), `${path}: only core/ and control/ may import core/`);
      if (closure.has(from)) assert.ok(closure.has(to), `${path}: the consumer closure imports outside itself`);
    }
  }
  if (closure.has(from)) assert.ok(!/\btransient\b|tstore|tload/.test(source), `${path}: the consumer closure must not use transient storage`);
}

const sources = files("src").filter((p) => p.endsWith(".sol")).length;
console.log(`checks: Node ${process.versions.node}; ${forgeVersion}; solc ${config.solc}; EVM ${config.evm_version}; bytecode_hash ${config.bytecode_hash}`);
console.log(`checks: ${sources} production Solidity sources; ${original.length} original sources with MIT headers; pins ${Object.entries(pins).map(([n, v]) => `${n}@${v}`).join(", ")}`);
