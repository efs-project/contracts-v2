// SPDX-License-Identifier: MIT
// A self-contained copy of the release units' artifacts, so fixtures can run from a known build while the working
// tree is being edited and rebuilt (by other agents, or in another worktree). It copies each unit's identity
// artifact, recovers every source file the units were compiled from by its metadata keccak256 (the working tree
// first, then `git show <rev>:<path>`), records the immutable layouts (from the AST build) and writes
// efs-artifacts-snapshot.json. Point the tools at it with EFS_ARTIFACTS_DIR=<dir>.
//
//   node tools/artifacts-snapshot.mjs --to <dir> [--from out] [--ast <from>/release-ast] [--rev HEAD] [--json]
//
// It refuses a set of unit artifacts that disagree about a shared source (a half-finished incremental build) and a
// source it cannot recover byte for byte. Exit 0 ok, 2 usage, 5 refused.
import { execFileSync } from "node:child_process";
import { cpSync, existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { dirname, join, relative, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { keccak256 } from "viem";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const SNAPSHOT_FILE = "efs-artifacts-snapshot.json";
/** Repository files the plan reads besides the artifacts (tools/deploy-plan.mjs repoFile). */
const EXTRA = ["vectors/layout.json", "test/harness/doubles/Factory.sol"];

export async function snapshot({ from = "out", ast, to, rev = "HEAD" } = {}) {
  if (!to) throw Object.assign(new Error("--to <dir> is required"), { exitCode: 2 });
  const fromDir = resolve(root, from);
  const astDir = resolve(root, ast ?? join(from, "release-ast"));
  const toDir = resolve(root, to);
  if (toDir === fromDir || toDir === root) throw Object.assign(new Error(`refusing to write the snapshot over ${to}`), { exitCode: 2 });
  const { UNITS } = await import("./deploy-plan.mjs");
  const need = new Map();
  const conflicts = [];
  const units = {};
  for (const [name, file] of Object.entries(UNITS)) {
    const p = join(fromDir, `${file}.sol`, `${name}.json`);
    if (!existsSync(p)) throw Object.assign(new Error(`${relative(root, p)} is missing`), { exitCode: 5 });
    const a = JSON.parse(readFileSync(p, "utf8"));
    units[name] = { file: `${file}.sol/${name}.json`, runtimeHash: keccak256(a.deployedBytecode.object), initcodeHash: keccak256(a.bytecode.object) };
    for (const [s, v] of Object.entries(a.metadata.sources)) {
      if (need.has(s) && need.get(s) !== v.keccak256) conflicts.push(`${s} (${name})`);
      need.set(s, v.keccak256);
    }
  }
  if (conflicts.length) throw Object.assign(new Error(`the unit artifacts in ${from} were not built together: they disagree about ${conflicts.join(", ")}`), { exitCode: 5 });

  const sources = {};
  const missing = [];
  const blobs = new Map();
  for (const [s, k] of need) {
    const disk = join(root, s);
    if (existsSync(disk) && keccak256(readFileSync(disk)) === k) { blobs.set(s, readFileSync(disk)); sources[s] = { keccak256: k, from: "worktree" }; continue; }
    let b = null;
    try { b = execFileSync("git", ["show", `${rev}:${s}`], { cwd: root, stdio: ["ignore", "pipe", "ignore"], maxBuffer: 64 << 20 }); } catch { /* not in rev */ }
    if (b && keccak256(b) === k) { blobs.set(s, b); sources[s] = { keccak256: k, from: `git:${rev}` }; continue; }
    missing.push(s);
  }
  if (missing.length) throw Object.assign(new Error(`cannot recover ${missing.length} source(s) byte for byte from the working tree or ${rev}: ${missing.join(", ")}`), { exitCode: 5 });

  rmSync(toDir, { recursive: true, force: true });
  for (const u of Object.values(units)) cpSync(join(fromDir, u.file), join(toDir, u.file));
  for (const [s, b] of blobs) { mkdirSync(dirname(join(toDir, "sources", s)), { recursive: true }); writeFileSync(join(toDir, "sources", s), b); }
  // the plan's other inputs: vectors/layout.json must carry the layout id compiled into Layout.sol
  const layoutSrc = blobs.get("src/core/layout/Layout.sol")?.toString();
  const compiledLayoutId = layoutSrc?.match(/LAYOUT_ID\s*=\s*(0x[0-9a-fA-F]{64})/)?.[1] ?? null;
  const extras = {};
  for (const e of EXTRA) {
    const candidates = [() => readFileSync(join(root, e)), () => execFileSync("git", ["show", `${rev}:${e}`], { cwd: root, stdio: ["ignore", "pipe", "ignore"], maxBuffer: 64 << 20 })];
    let chosen = null;
    for (const [i, c] of candidates.entries()) {
      let b;
      try { b = c(); } catch { continue; }
      if (e === "vectors/layout.json" && compiledLayoutId && JSON.parse(b.toString()).layoutId !== compiledLayoutId) continue;
      chosen = { b, from: i === 0 ? "worktree" : `git:${rev}` };
      break;
    }
    if (!chosen) throw Object.assign(new Error(`cannot find a ${e} consistent with the snapshot (compiled LAYOUT_ID ${compiledLayoutId})`), { exitCode: 5 });
    mkdirSync(dirname(join(toDir, "sources", e)), { recursive: true });
    writeFileSync(join(toDir, "sources", e), chosen.b);
    extras[e] = { keccak256: keccak256(chosen.b), from: chosen.from };
  }
  const manifest = { schema: "efs-artifacts-snapshot/1", createdAt: new Date().toISOString(), from: relative(root, fromDir) || ".", ast: relative(root, astDir), rev, units, sources, extras, immutables: null };
  writeFileSync(join(toDir, SNAPSHOT_FILE), `${JSON.stringify(manifest, null, 2)}\n`);

  // immutable layouts, resolved now against the AST build (its bytecode must equal the snapshot's), then frozen
  process.env.EFS_ARTIFACTS_DIR = toDir;
  process.env.EFS_AST_DIR = astDir;
  const plan = await import(`${pathToFileURL(join(root, "tools/deploy-plan.mjs")).href}?snapshot=${Date.now()}`);
  const immutables = {};
  for (const name of Object.keys(UNITS)) immutables[name] = plan.immutableLayout(name);
  manifest.immutables = immutables;
  writeFileSync(join(toDir, SNAPSHOT_FILE), `${JSON.stringify(manifest, null, 2)}\n`);
  return { ok: true, dir: toDir, units: Object.keys(units).length, sources: Object.keys(sources).length, fromWorktree: Object.values(sources).filter((s) => s.from === "worktree").length, fromRev: Object.values(sources).filter((s) => s.from !== "worktree").length };
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const argv = process.argv.slice(2);
  const o = {};
  for (let i = 0; i < argv.length; i++) {
    const k = argv[i].replace(/^--/, "");
    if (k === "json") { o.json = true; continue; }
    if (!["from", "ast", "to", "rev"].includes(k) || argv[i + 1] === undefined) { console.error("usage: node tools/artifacts-snapshot.mjs --to <dir> [--from out] [--ast <dir>] [--rev HEAD] [--json]"); process.exit(2); }
    o[k] = argv[++i];
  }
  try {
    const r = await snapshot(o);
    if (o.json) process.stdout.write(`${JSON.stringify(r)}\n`);
    else console.log(`artifacts-snapshot: ${r.units} units, ${r.sources} sources (${r.fromWorktree} from the working tree, ${r.fromRev} from ${o.rev ?? "HEAD"}) → ${relative(root, r.dir)}; use EFS_ARTIFACTS_DIR=${relative(root, r.dir)}`);
  } catch (e) {
    if (o.json) process.stdout.write(`${JSON.stringify({ ok: false, error: { message: e.message, exitCode: e.exitCode ?? 5 } })}\n`);
    else console.error(`artifacts-snapshot: ${e.message}`);
    process.exit(e.exitCode ?? 5);
  }
}
