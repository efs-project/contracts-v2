// SPDX-License-Identifier: MIT
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
assert.equal(config.bytecode_hash, "ipfs", "foundation keeps the compiler's metadata default");

const files = (dir) => readdirSync(join(root, dir), { withFileTypes: true }).flatMap((e) =>
  e.isDirectory() ? files(`${dir}/${e.name}`) : [`${dir}/${e.name}`]);
assert.deepEqual(files("src").filter((p) => p.endsWith(".sol")), [],
  "foundation defines no production Solidity contracts or interfaces");
for (const path of [...files("tools"), ...files("test")]) {
  if (/\.(?:mjs|sol)$/.test(path)) assert.ok(read(path).startsWith("// SPDX-License-Identifier: MIT"), path);
}
const lock = read("soldeer.lock");
assert.match(lock, /name = "forge-std"\s+version = "1\.16\.2"/);
assert.ok(existsSync(join(root, "dependencies/forge-std-1.16.2/LICENSE-MIT")));
assert.ok(existsSync(join(root, "dependencies/forge-std-1.16.2/LICENSE-APACHE")));
console.log(`foundation checks: Node ${process.versions.node}; ${forgeVersion}; configured solc ${config.solc}; EVM ${config.evm_version}`);
console.log("production Solidity sources: 0; test-only toolchain fixture; dependency licenses retained");
