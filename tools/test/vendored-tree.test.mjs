// SPDX-License-Identifier: MIT
// A consumer (the SDK's CI) vendors tools/{efs-fixture,fixture-registry,deploy-plan}.mjs with schemas/, artifacts/,
// release/ and deploy/ and has no Foundry build. The tools must import and reproduce the committed plan from that
// tree alone: no out/, no EFS_ARTIFACTS_DIR.
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { cpSync, mkdirSync, mkdtempSync, readFileSync, rmSync, symlinkSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "../..");

test("a vendored tree without out/ reproduces the committed plan", () => {
  const dir = mkdtempSync(join(tmpdir(), "efs-vendored-"));
  try {
    mkdirSync(join(dir, "tools"));
    for (const f of ["efs-fixture.mjs", "fixture-registry.mjs", "deploy-plan.mjs"]) cpSync(join(root, "tools", f), join(dir, "tools", f));
    for (const d of ["schemas", "artifacts", "release", "deploy"]) cpSync(join(root, d), join(dir, d), { recursive: true });
    symlinkSync(join(root, "node_modules"), join(dir, "node_modules"));
    const env = { ...process.env };
    delete env.EFS_ARTIFACTS_DIR;
    delete env.EFS_AST_DIR;
    execFileSync(process.execPath, ["tools/deploy-plan.mjs", "--artifacts", "artifacts", "--out", "plan.json"], { cwd: dir, env, stdio: "pipe" });
    const [made, committed] = [join(dir, "plan.json"), join(root, "deploy/plan.json")].map((p) => JSON.parse(readFileSync(p, "utf8")));
    assert.equal(made.planHash, committed.planHash);
    // the fixture CLI imports too (usage error, not a crash at import)
    const help = execFileSync(process.execPath, ["tools/efs-fixture.mjs", "list", "--home", join(dir, "home"), "--json"], { cwd: dir, env, stdio: "pipe" }).toString();
    assert.ok(JSON.parse(help));
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});
