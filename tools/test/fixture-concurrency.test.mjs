// SPDX-License-Identifier: MIT
// Three fixture instances started at the same instant from one checkout, with no --name and no --port: they get
// three names, three ports, three anvils; each `up` has already run every verify check; a second verify of each
// passes; list shows exactly them; down stops exactly them; afterwards no lease, no port claim and none of their
// processes remain. Every anvil runs under the TTL watchdog (--ttl 300) in case the test itself dies.
//
//   node --test tools/test/fixture-concurrency.test.mjs        (EFS_ARTIFACTS_DIR picks the artifacts, as for up)
//
// It skips, saying why, when the plan cannot be built from the current artifacts (for example out/ mid-rebuild):
// make a snapshot with tools/artifacts-snapshot.mjs or point EFS_ARTIFACTS_DIR at artifacts/.
import assert from "node:assert/strict";
import { execFileSync, spawn } from "node:child_process";
import { mkdtempSync, readdirSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { after, test } from "node:test";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const CLI = resolve(here, "../efs-fixture.mjs");
const home = mkdtempSync(join(tmpdir(), "efs-fixture-concurrency-"));
const env = { ...process.env, EFS_FIXTURE_HOME: home };
delete env.EFS_FIXTURE_NAME;

/** Run the CLI with --json; resolve {code, json} (exactly one JSON object on stdout). */
function cli(args, timeoutMs = 240_000) {
  return new Promise((res) => {
    const p = spawn(process.execPath, [CLI, ...args, "--json"], { env, stdio: ["ignore", "pipe", "pipe"], timeout: timeoutMs });
    let out = "";
    let err = "";
    p.stdout.on("data", (d) => { out += d; });
    p.stderr.on("data", (d) => { err += d; });
    p.on("close", (code) => {
      let json = null;
      try { json = JSON.parse(out); } catch { /* reported below */ }
      res({ code, json, out, err });
    });
  });
}
const pgrepAnvil = () => { try { return execFileSync("pgrep", ["-x", "anvil"]).toString().split("\n").filter(Boolean).map(Number); } catch { return []; } };
const alive = (pid) => { try { process.kill(pid, 0); return true; } catch { return false; } };

after(async () => {
  // belt and braces: an identity-checked down of anything this test leased, then the home
  for (const f of (() => { try { return readdirSync(join(home, "leases")); } catch { return []; } })()) {
    if (f.endsWith(".json")) await cli(["down", "--name", f.slice(0, -5)]);
  }
  rmSync(home, { recursive: true, force: true });
});

test("three instances started at once, verified, listed and stopped, leave nothing behind", { timeout: 300_000 }, async (t) => {
  const { buildPlan } = await import("../deploy-plan.mjs");
  try { await buildPlan(); } catch (e) { t.skip(`the plan cannot be built from the current artifacts: ${e.message.split("\n")[0]}`); return; }

  const t0 = Date.now();
  const ups = await Promise.all([
    cli(["up", "--ttl", "300"]),
    cli(["up", "--ttl", "300"]),
    cli(["up", "--ttl", "300", "--no-unlocked", "--fresh", "--chain-id", "3133702"]),
  ]);
  const upMs = Date.now() - t0;
  for (const u of ups) assert.equal(u.code, 0, `up failed: ${u.out}\n${u.err.slice(-2000)}`);
  const r = ups.map((u) => u.json);
  for (const x of r) {
    assert.equal(x.ok, true);
    assert.equal(x.verified.skipped, false);
    assert.equal(x.verified.ok, true);
    assert.match(x.rpcUrl, new RegExp(`:${x.port}$`));
  }
  assert.equal(new Set(r.map((x) => x.name)).size, 3, "names");
  assert.equal(new Set(r.map((x) => x.port)).size, 3, "ports");
  assert.equal(new Set(r.map((x) => x.pid)).size, 3, "pids");
  assert.deepEqual(r.map((x) => x.signerCapable), [true, true, false]);
  assert.notEqual(r[2].realmSalt, r[0].realmSalt);
  assert.notEqual(r[2].ledger, r[0].ledger, "a fresh salt on another chain deploys another ledger");
  for (const x of r) assert.ok(pgrepAnvil().includes(x.pid), `pid ${x.pid} is an anvil`);
  console.log(`# 3 concurrent up (each with its in-up verify) in ${upMs} ms: ${r.map((x) => `${x.name} → ${x.rpcUrl} (pid ${x.pid}, chain ${x.chainId}, verify ${x.verified.checks} checks in ${x.verified.ms} ms)`).join("; ")}`);

  const vs = await Promise.all(r.map((x) => cli(["verify", "--name", x.name])));
  for (const v of vs) {
    assert.equal(v.code, 0, v.out);
    assert.equal(v.json.ok, true);
    assert.deepEqual(v.json.failures, []);
    assert.ok(v.json.coldPin.calls <= 9 && v.json.coldPin.envelopes <= 2);
  }

  const l = await cli(["list"]);
  assert.equal(l.code, 0);
  assert.deepEqual(l.json.leases.map((x) => x.name).sort(), r.map((x) => x.name).sort());
  assert.ok(l.json.leases.every((x) => x.liveness === "live" && x.state === "ready"));

  const ds = await Promise.all(r.map((x) => cli(["down", "--name", x.name, "--purge"])));
  for (const [i, d] of ds.entries()) {
    assert.equal(d.code, 0, d.out);
    assert.equal(d.json.stopped, r[i].pid);
  }
  assert.deepEqual(readdirSync(join(home, "leases")), []);
  assert.deepEqual(readdirSync(join(home, "ports")), []);
  assert.deepEqual(readdirSync(join(home, "instances")), []);
  for (const x of r) assert.ok(!alive(x.pid), `pid ${x.pid} still alive`);
  const left = pgrepAnvil().filter((p) => r.some((x) => x.pid === p));
  assert.deepEqual(left, []);
  const gone = await cli(["status", "--name", r[0].name]);
  assert.equal(gone.code, 4, "a stopped instance is not found (exit 4)");
});
