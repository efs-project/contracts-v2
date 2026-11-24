// SPDX-License-Identifier: MIT
// The registry under contention: simultaneous allocations from separate processes never share a port, a bound
// port is skipped, explicit ports fail clearly, stale leases are broken, gc touches only the dead, and `down` never
// signals a process that is not the anvil its lease recorded. Each test uses its own registry home; no anvil runs.
//
//   node --test tools/test/fixture-registry.test.mjs
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { mkdirSync, mkdtempSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { createServer } from "node:net";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { after, test } from "node:test";
import { fileURLToPath, pathToFileURL } from "node:url";
import { EXIT, FixtureError, allocate, gc, leasePath, list, lookup, portBusy, procInfo, release } from "../fixture-registry.mjs";

const here = dirname(fileURLToPath(import.meta.url));
const REGISTRY = pathToFileURL(resolve(here, "../fixture-registry.mjs")).href;
const homes = [];
const freshHome = () => { const h = mkdtempSync(join(tmpdir(), "efs-fixture-test-")); homes.push(h); return h; };
after(() => { for (const h of homes) rmSync(h, { recursive: true, force: true }); });

/** A range of `n` ports that nothing is bound to right now (searched upward from `from`). */
async function freeRange(n, from) {
  for (let lo = from; lo < from + 2000; lo += n) {
    let ok = true;
    for (let p = lo; p < lo + n && ok; p++) ok = !(await portBusy(p));
    if (ok) return [lo, lo + n - 1];
  }
  throw new Error("no free test range");
}

/** `n` processes that all call allocate() at the same instant, hold their lease until stdin closes, then release. */
async function race(n, { home, range }) {
  const at = Date.now() + 1500;
  const script = `
    import { allocate, release } from ${JSON.stringify(REGISTRY)};
    const [name, home, lo, hi, at] = process.argv.slice(1);
    while (Date.now() < Number(at)) await new Promise((r) => setTimeout(r, 1));
    let out;
    try { const l = await allocate({ kind: "chain", name, home, range: [Number(lo), Number(hi)] }); out = { ok: true, port: l.port }; }
    catch (e) { out = { ok: false, code: e.code, exitCode: e.exitCode }; }
    process.stdout.write(JSON.stringify(out) + "\\n");
    process.stdin.resume();
    process.stdin.on("end", () => { if (out.ok) release(name, home); process.exit(0); });
  `;
  const kids = Array.from({ length: n }, (_, i) => spawn(process.execPath, ["--input-type=module", "-e", script, `race-${i}`, home, String(range[0]), String(range[1]), String(at)], { stdio: ["pipe", "pipe", "inherit"], timeout: 60_000 }));
  const results = await Promise.all(kids.map((k) => new Promise((res) => {
    let s = "";
    k.stdout.on("data", (d) => { s += d; if (s.includes("\n")) res(JSON.parse(s)); });
  })));
  const live = list({ home });
  for (const k of kids) k.stdin.end();
  await Promise.all(kids.map((k) => new Promise((res) => (k.exitCode !== null ? res() : k.once("exit", res)))));
  return { results, live };
}

test("simultaneous allocations from separate processes never share a port", { timeout: 90_000 }, async () => {
  const home = freshHome();
  const range = await freeRange(12, 8900);
  const { results, live } = await race(12, { home, range });
  assert.ok(results.every((r) => r.ok), JSON.stringify(results));
  const ports = results.map((r) => r.port);
  assert.equal(new Set(ports).size, 12, `duplicate ports: ${ports}`);
  assert.equal(live.length, 12);
  assert.ok(live.every((l) => l.liveness === "live" && l.state === "allocated"));
  console.log(`# 12 simultaneous allocations got ports ${[...ports].sort((a, b) => a - b).join(", ")}`);
  assert.deepEqual(readdirSync(join(home, "leases")), []);
  assert.deepEqual(readdirSync(join(home, "ports")), []);
});

test("more contenders than ports: each free port goes to exactly one, the rest get exit 3", { timeout: 90_000 }, async () => {
  const home = freshHome();
  const range = await freeRange(3, 8920);
  const { results } = await race(8, { home, range });
  const won = results.filter((r) => r.ok).map((r) => r.port);
  assert.equal(won.length, 3, JSON.stringify(results));
  assert.equal(new Set(won).size, 3);
  for (const r of results.filter((x) => !x.ok)) assert.deepEqual([r.code, r.exitCode], ["NO_FREE_PORT", EXIT.CONFLICT]);
  console.log(`# 8 contenders for ${range.join("–")}: winners ${won.sort().join(", ")}, ${results.length - won.length} refused with exit 3`);
});

test("a port bound outside the registry is skipped, and refused when asked for explicitly", async () => {
  const home = freshHome();
  const [lo, hi] = await freeRange(3, 8940);
  const server = createServer();
  await new Promise((r) => server.listen(lo, "127.0.0.1", r));
  try {
    const l = await allocate({ name: "skips", home, range: [lo, hi] });
    assert.equal(l.port, lo + 1);
    await assert.rejects(allocate({ name: "explicit-busy", home, port: lo }), (e) => e instanceof FixtureError && e.code === "PORT_BUSY" && e.exitCode === EXIT.CONFLICT);
    await assert.rejects(allocate({ name: "explicit-leased", home, port: lo + 1 }), (e) => e.code === "PORT_LEASED" && e.exitCode === EXIT.CONFLICT);
    await assert.rejects(allocate({ name: "foreign", home, port: 60742 }), (e) => e.code === "PORT_FOREIGN" && e.exitCode === EXIT.CONFLICT);
    await assert.rejects(allocate({ name: "skips", home, range: [lo, hi] }), (e) => e.code === "NAME_LEASED" && e.exitCode === EXIT.CONFLICT);
    await assert.rejects(allocate({ name: "bad name!", home }), (e) => e.exitCode === EXIT.USAGE);
    // a failed allocation leaves no lease behind
    assert.deepEqual(list({ home }).map((x) => x.name), ["skips"]);
    assert.ok(release("skips", home));
  } finally { server.close(); }
});

test("a lease whose holder died is broken by the next allocation; gc removes only the dead", { timeout: 30_000 }, async () => {
  const home = freshHome();
  const range = await freeRange(4, 8960);
  // a process that allocates and dies without releasing
  const script = `import { allocate } from ${JSON.stringify(REGISTRY)}; await allocate({ name: process.argv[1], home: process.argv[2], range: [${range[0]}, ${range[1]}] });`;
  for (const n of ["ghost", "ghost2"]) {
    await new Promise((res, rej) => spawn(process.execPath, ["--input-type=module", "-e", script, n, home], { stdio: "inherit", timeout: 20_000 }).once("exit", (c) => (c === 0 ? res() : rej(new Error(`exit ${c}`)))));
  }
  assert.deepEqual(list({ home }).map((l) => [l.name, l.liveness]), [["ghost", "dead"], ["ghost2", "dead"]]);
  const reborn = await allocate({ name: "ghost", home, range });
  assert.equal(reborn.pid, process.pid);
  assert.equal(lookup("ghost", home).liveness, "live");
  const removed = gc({ home });
  assert.deepEqual(removed.leases, ["ghost2"]);
  assert.deepEqual(list({ home }).map((l) => l.name), ["ghost"]);
  // the reborn lease holds its port live, so another allocation gets a different one
  const again = await allocate({ name: "third", home, range });
  assert.notEqual(again.port, reborn.port);
  release("ghost", home);
  release("third", home);
  assert.deepEqual(readdirSync(join(home, "ports")), []);
});

test("down never signals a process that is not the anvil its lease recorded", { timeout: 30_000 }, async () => {
  const home = freshHome();
  const { down } = await import("../efs-fixture.mjs");
  mkdirSync(join(home, "leases"), { recursive: true });
  const victim = spawn(process.execPath, ["-e", "setTimeout(() => {}, 25000)"], { stdio: "ignore", timeout: 30_000 });
  await new Promise((r) => setTimeout(r, 300));
  const info = procInfo(victim.pid);
  assert.ok(info, "victim started");
  const base = { schema: "efs-fixture-lease/1", kind: "chain", state: "ready", generation: 1, owner: { pid: process.pid, user: "test" }, hostname: (await import("node:os")).hostname(), host: "127.0.0.1", port: 8999, url: "http://127.0.0.1:8999", ttl: 0, startedAt: new Date().toISOString(), expiresAt: null, chainId: 31337 };
  try {
    // 1. the pid is live and its identity matches, but it is not anvil: refused (exit 3), not signalled
    writeFileSync(leasePath("impostor", home), JSON.stringify({ ...base, name: "impostor", pid: info.pid, startTime: info.startTime, command: info.command }));
    await assert.rejects(down({ name: "impostor", home }), (e) => e.code === "NOT_ANVIL_YET" && e.exitCode === EXIT.CONFLICT);
    // 2. a lease naming that pid with another start time (a reused pid): dead, so the lease goes and nothing is signalled
    writeFileSync(leasePath("reused", home), JSON.stringify({ ...base, name: "reused", pid: info.pid, startTime: "Thu Jan  1 00:00:00 1970", command: `anvil --port 8999 --host 127.0.0.1` }));
    const r = await down({ name: "reused", home });
    assert.deepEqual([r.ok, r.stopped, r.wasLive], [true, null, false]);
    assert.equal(lookup("reused", home), null);
    // the victim survived both
    assert.doesNotThrow(() => process.kill(victim.pid, 0));
    assert.equal(procInfo(victim.pid)?.startTime, info.startTime);
    await assert.rejects(down({ name: "nobody", home }), (e) => e.code === "NO_INSTANCE" && e.exitCode === EXIT.NOT_FOUND);
  } finally { victim.kill(); }
});
